{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}

module Data.Conduit.Network.Stream
  ( -- * Network streams
    Stream
    -- ** Sending
  , Sendable, send1, sendList
    -- ** Receiving
  , Streamable (receive), receiveLast, close
    -- ** Manual sending/receiving
  , next
  , (~~)
  , sink1, sinkList, sinkList'
  --, sinkListStart, sinkListElems, sinkListEnd
  ) where

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
import Data.Conduit.Network.Stream.Internal

-- | Lifted version of @($$)@
infixr 0 ~~
(~~) :: Monad m => Source (Stream m) a -> Sink a (Stream m) b -> m b
src ~~ sink = stream_base $ src C.$$ sink

class Sendable a m where
  encode :: Conduit a (Stream m) ByteString

instance Monad m => Sendable ByteString m where
  encode = encodeBS

instance Monad m => Sendable (Int, BL.ByteString) m where
  encode = encodeLazyBS

-- | Send one single 'ByteString' over the network connection (if there is more
-- than one 'ByteString' in the pipe it will be discarded)
send1 :: (Monad m, Sendable a m) => AppData m -> Source (Stream m) a -> m ()
send1 ad src = src ~~ sink1 ad

-- | Send all 'ByteString's in the pipe as a list over the network connection
sendList :: (Monad m, Sendable a m) => AppData m -> Source (Stream m) a -> m ()
sendList ad src = src ~~ sinkList ad

sink1 :: (Monad m, Sendable a m) => AppData m -> Sink a (Stream m) ()
sink1 ad = do
  CL.isolate 1 =$ encode =$ sink
  CL.sinkNull
 where
  sink = transPipe lift (appSink ad)

sinkList :: (Monad m, Sendable a m) => AppData m -> Sink a (Stream m) ()
sinkList ad = do
  sinkListStart ad
  sinkListElems ad
  sinkListEnd   ad

class Streamable source m where
  -- | Get the next package from a streamable source (calls 'next'
  -- automatically)
  receive :: source -> Sink BL.ByteString (Stream m) b -> m (ResumableSource (Stream m) ByteString, b)

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

-- | Send multiple sinks in the same list
sinkList'
  :: (Monad m, Sendable a m)
  => AppData m
  -> (Sink a (Stream m) () -> Sink b (Stream m) c)
  -> Sink b (Stream m) c
sinkList' ad f = do
  sinkListStart ad
  b <- f (sinkListElems ad)
  sinkListEnd ad
  return b

sinkListStart, sinkListEnd
  :: Monad m => AppData m -> Sink a (Stream m) ()
sinkListStart ad = yield (BS.pack listStart) =$ transPipe lift (appSink ad)
sinkListEnd   ad = yield (BS.pack listEnd)   =$ transPipe lift (appSink ad)

sinkListElems
  :: (Monad m, Sendable a m) => AppData m -> Sink a (Stream m) ()
sinkListElems ad = encode =$ transPipe lift (appSink ad)
