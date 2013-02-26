{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}

-- |
module Data.Conduit.Network.Stream
  ( -- * Network streams
    StreamData, toStreamData, closeStream
    -- ** Sending
  , Sendable(..), EncodedBS, send
    -- ** Receiving
  , Receivable(..), receive
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

toStreamData :: MonadResource n => AppData m -> n (StreamData m)
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

class Receivable a m where
  -- | `decode` is used after receiving the individual conduit block elements.
  decode :: Conduit BL.ByteString m a

-- | Instance for strict bytestrings. Note that this uses `BL.toStrict` for the
-- conversion, which is rather expensive. Try to use lazy bytestrings if
-- possible.
instance Monad m => Receivable ByteString m where
  decode = CL.map BL.toStrict

-- | For lazy bytestrings, `decode` is the identity conduit.
instance Monad m => Receivable BL.ByteString m where
  decode = CI.ConduitM $ CI.idP

-- | Receive the next conduit block. Might fail with `ClosedStream` if used on a
-- closed stream.
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
