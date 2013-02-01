{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Data.Conduit.Network.Stream
  ( -- * Network streams
    Stream
    -- ** Sending
  , send1, sendList
    -- ** Receiving
  , Streamable (receive), next, receiveLast, close
  --, (~>)
  ) where

import Control.Applicative
import Control.Monad.Trans
import Control.Monad.Trans.Resource
import Data.ByteString (ByteString)
import Data.Conduit hiding (($$))
import Data.Conduit.Network

import qualified Data.Conduit         as C 
import qualified Data.Conduit.List    as CL
import qualified Data.Conduit.Binary  as CB
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BL

import Data.Conduit.Network.Stream.Exceptions
import Data.Conduit.Network.Stream.Header

-- | 'BL.ByteString' stream
newtype Stream m a = Stream { stream_base :: m a }
  deriving (Monad, MonadIO, Functor, Applicative)

instance MonadTrans Stream where
  lift f = Stream f

instance (MonadThrow m) => MonadThrow (Stream m) where
  monadThrow e = lift $ monadThrow e

instance (MonadResource m, MonadIO m) => MonadResource (Stream m) where
  liftResourceT t = lift $ liftResourceT t

-- | Alias for '(=$)'
--(~>) :: Monad m => Conduit a (Stream m) b -> Sink b (Stream m) c -> Sink a (Stream m) c
--(~>) = (=$)

-- | Lifted version of @($$)@
($$) :: Monad m => Source (Stream m) a -> Sink a (Stream m) b -> m b
src $$ sink = stream_base $ src C.$$ sink

-- | Send one single 'ByteString' over the network connection (if there is more
-- than one 'ByteString' in the pipe it will be discarded)
send1 :: Monad m => AppData m -> Source (Stream m) ByteString -> m ()
send1 ad src = src $$ do
  CL.isolate 1 =$ encodeBS =$ sink
  CL.sinkNull
 where
  sink = transPipe lift (appSink ad)

-- | Send all 'ByteString's in the pipe as a list over the network connection
sendList :: Monad m => AppData m -> Source (Stream m) ByteString -> m ()
sendList ad src = src $$ do
  start    =$ sink
  encodeBS =$ sink
  end      =$ sink
 where
  sink  = transPipe lift (appSink ad)
  start = yield $ BS.pack listStart
  end   = yield $ BS.pack listEnd

encodeBS :: Monad m => Conduit ByteString (Stream m) ByteString 
encodeBS = awaitForever $ \bs -> do
  yield $ BS.pack (varint $ BS.length bs)
  mapM_ yield $ blocks bs
 where
  blocks bs | BS.null bs = []
            | otherwise  =
              let (f,r) = BS.splitAt 4096 bs
               in f : blocks r

class Streamable a m where
  -- | Get the next package from a streamable source (calls 'next'
  -- automatically)
  receive :: a -> Sink BL.ByteString (Stream m) b -> m (ResumableSource (Stream m) ByteString, b)

instance MonadResource m => Streamable (AppData m) m where
  receive ad sink = stream_base $
    transPipe lift (appSource ad) $$+ next =$ sink

instance MonadResource m => Streamable (ResumableSource (Stream m) ByteString) m where
  receive src sink = stream_base $
    src $$++ next =$ sink

-- | Get the next package from the stream and close the source afterwards
receiveLast
  :: MonadResource m
  => ResumableSource (Stream m) ByteString
  -> Sink BL.ByteString (Stream m) a
  -> m a
receiveLast src sink = stream_base $
  src $$+- next =$ sink

-- | Close a resumable source
close
  :: MonadResource m
  => ResumableSource (Stream m) ByteString
  -> m ()
close src = stream_base $
  src $$+- return ()

-- | Get the next package from the stream (whether it's a single 'BL.ByteString' or
-- a list)
next :: MonadResource m => Conduit ByteString (Stream m) BL.ByteString
next = do
  h <- decodeHeader
  case h of
       VarInt l   -> single l
       ListSTART  -> list
       EndOfInput -> return ()
       _          -> monadThrow $ UnexpectedHeader h
 where
  single l = CB.take l >>= yield
  list = do
    h <- decodeHeader
    case h of
         VarInt l -> single l >> list
         ListEND  -> return ()
         _        -> monadThrow $ UnexpectedHeader h
