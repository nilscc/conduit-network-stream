{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}

{- |

Module      :  Data.Conduit.Network.Stream
Copyright   :  Nils Schweinsberg
License     :  BSD-style

Maintainer  :  Nils Schweinsberg <mail@nils.cc>
Stability   :  experimental


Easy to use network streaming with conduits. This library properly encodes
conduit blocks over a network connection such that

 - each `await` corresponds to exactly one `yield` and

 - each `receive` corresponds to exactly one `send`.

It also supports sending and receiving of custom data types via the
`Sendable` and `Receivable` instances.

A simple server/client example (using @-XOverloadedStrings@):

> import           Control.Monad.Trans
> import qualified Data.ByteString             as Strict
> import qualified Data.ByteString.Lazy        as Lazy
> import           Data.Conduit
> import qualified Data.Conduit.List           as CL
> import           Data.Conduit.Network
> import           Data.Conduit.Network.Stream
>
> client :: IO ()
> client = runResourceT $ runTCPClient (clientSettings ..) $ \appData -> do       
>
>     streamData <- toStreamData appData
>
>     send streamData $ mapM_ yield (["ab", "cd", "ef"] :: [Strict.ByteString])
>     send streamData $ mapM_ yield (["123", "456"]     :: [Strict.ByteString])
>
>     closeStream streamData
>
> server :: IO ()
> server = runResourceT $ runTCPServer (serverSettings ..) $ \appData -> do
>
>     streamData <- toStreamData appData
>
>     bs  <- receive streamData $ CL.consume
>     liftIO $ print (bs  :: [Lazy.ByteString])
>
>     bs' <- receive streamData $ CL.consume
>     liftIO $ print (bs' :: [Lazy.ByteString])
> 
>     closeStream streamData

-}

module Data.Conduit.Network.Stream
  ( -- * Network streams
    StreamData, toStreamData, closeStream
    -- ** Sending
  , send
  , Sendable(..), EncodedBS
    -- ** Receiving
  , receive
  , Receivable(..)
    -- ** Bi-directional conversations
  , streamSink
  , withElementSink
  ) where

import Control.Concurrent.MVar
import Control.Monad.Reader
import Control.Monad.Trans.Resource
import Data.ByteString (ByteString)
import Data.Conduit hiding (($$))
import Data.Conduit.Network

import qualified Data.Conduit         as C 
import qualified Data.Conduit.List    as CL
import qualified Data.Conduit.Internal as CI
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BL

import Data.Conduit.Network.Stream.Exceptions
import Data.Conduit.Network.Stream.Header
import Data.Conduit.Network.Stream.Internal

sinkCondStart, sinkCondEnd
  :: Monad m
  => StreamData m -> Sink a m ()
sinkCondStart sd = yield (BS.pack condStart) =$ streamDataSink sd
sinkCondEnd   sd = yield (BS.pack condEnd)   =$ streamDataSink sd

sinkCondElems
  :: (Monad m, Sendable m a)
  => StreamData m -> Sink a m ()
sinkCondElems sd = encode =$ CL.map (\(EncodedBS bs) -> bs) =$ streamDataSink sd

toStreamData :: MonadIO n => AppData m -> n (StreamData m)
toStreamData ad = do
  src <- liftIO $ newMVar (NewSource ad)
  let sd = StreamData src (appSink ad)
  --register $ closeStream sd
  return sd

-- | Close current stream. In order to guarantee process resource finalization,
-- you /must/ use this operator after using `receive`.
closeStream
  :: MonadResource m
  => StreamData m
  -> m ()
closeStream sd = do
  src <- liftIO $ takeMVar (streamDataSource sd)
  case src of
       OpenSource s -> s $$+- return ()
       _            -> return ()

--------------------------------------------------------------------------------
-- Receiving data

-- | `decode` is used after receiving the individual conduit block elements.
-- It is therefore not necessary to reuse other `decode` instances (in
-- contrast to `Sendable` instance definitions).
class Receivable a m where
  decode :: Conduit BL.ByteString m a

-- | Instance for strict bytestrings. Note that this uses `BL.toStrict` for the
-- conversion from lazy bytestrings, which is rather expensive. Try to use lazy
-- bytestrings if possible.
instance Monad m => Receivable ByteString m where
  decode = CL.map BL.toStrict

-- | For lazy bytestrings, `decode` is the identity conduit.
instance Monad m => Receivable BL.ByteString m where
  decode = CI.ConduitM $ CI.idP

-- | Receive the next conduit block. Might fail with the `ClosedStream`
-- exception if used on a stream that has been closed by `closeStream`.
receive :: (MonadResource m, Receivable a m) => StreamData m -> Sink a m b -> m b
receive sd sink = do
  -- get current source (and block MVar, just in case)
  src <- liftIO $ takeMVar (streamDataSource sd)
  (next,a) <- case src of
    NewSource ad    -> appSource ad $$+  decodeCondBlock =$= decode =$ sink
    OpenSource rsrc -> rsrc         $$++ decodeCondBlock =$= decode =$  sink
    ClosedSource    -> monadThrow $ ClosedStream
  liftIO $ putMVar (streamDataSource sd) (OpenSource next)
  return a

--------------------------------------------------------------------------------
-- Sending data

-- | Newtype for properly encoded bytestrings.
newtype EncodedBS = EncodedBS ByteString

-- | To define your own `Sendable` instances, reuse the instances for strict and
-- lazy bytestrings, for example for "Data.Text":
--
-- > instance (Monad m, Sendable m Data.ByteString.ByteString) => Sendable m Text where
-- >     encode = Data.Conduit.List.map encodeUtf8 =$= encode
class Sendable m a where
  -- | `encode` is called before sending out conduit block elements. Each
  -- element has to be encoded either as strict `ByteString` or as lazy `BL.ByteString`
  -- with a known length.
  encode :: Conduit a m EncodedBS

-- | Instance for strict bytestrings, using a specialized version of `encode`.
instance Monad m => Sendable m ByteString where
  encode = encodeBS =$= CL.map EncodedBS

-- | Instance for lazy bytestrings with a known length, using a specialized
-- version of `encode`.
instance Monad m => Sendable m (Int, BL.ByteString) where
  encode = encodeLazyBS =$= CL.map EncodedBS

-- | Instance for lazy bytestrings which calculates the length of the
-- `BL.ByteString` before calling the @(Int, Data.ByteString.Lazy.ByteString)@
-- instance of `Sendable`.
instance Monad m => Sendable m BL.ByteString where
  encode = CL.map (\bs -> (len bs, bs)) =$= encode
   where
    len :: BL.ByteString -> Int
    len bs = fromIntegral $ BL.length bs

-- | Send one conduit block.
send :: (Monad m, Sendable m a) => StreamData m -> Source m a -> m ()
send sd src = src C.$$ streamSink sd


--------------------------------------------------------------------------------
-- Bi-directional conversations

-- | For bi-directional conversations you sometimes need the sink of the current
-- stream, since you can't use `send` within another `receive`.
--
-- A simple example:
--
-- > receive streamData $
-- >     myConduit =$ streamSink streamData
--
-- Note, that each `streamSink` marks its own conduit block. If you want to sink
-- single block elements, use `withElementSink` instead.
streamSink
  :: (Monad m, Sendable m a)
  => StreamData m
  -> Sink a m ()
streamSink sd = do
  sinkCondStart sd
  sinkCondElems sd
  sinkCondEnd   sd

-- | Sink single elements inside the same conduit block. Example:
--
-- > receive streamData $ withElementSink $ \sinkElem -> do
-- >     yield singleElem =$ sinkElem
-- >     mapM_ yield moreElems =$ sinkElem
withElementSink
  :: (Monad m, Sendable m a)
  => StreamData m
  -> (Sink a m () -> Sink b m c)
  -> Sink b m c
withElementSink sd run = do
  sinkCondStart sd
  res <- run (sinkCondElems sd)
  sinkCondEnd   sd
  return res
