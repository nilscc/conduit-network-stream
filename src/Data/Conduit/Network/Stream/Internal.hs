{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Data.Conduit.Network.Stream.Internal where

import Control.Applicative
import Control.Concurrent.MVar
import Control.Monad.Reader
--import Control.Monad.Trans
import Control.Monad.Trans.Resource
import Data.Conduit
import Data.Conduit.Network
import Data.ByteString (ByteString)

import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Conduit.Binary  as CB

import Data.Conduit.Network.Stream.Exceptions
import Data.Conduit.Network.Stream.Header

data StreamSource m
  = NewSource (AppData m)
  | OpenSource (ResumableSource m ByteString)
  | ClosedSource

data StreamData m = StreamData
  { streamDataSource  :: MVar (StreamSource m)
  , streamDataSink    :: Sink ByteString m () }

-- | 'BL.ByteString' stream
newtype StreamT m a = StreamT { stream_base :: ReaderT (StreamData m) m a }
  deriving (Monad, MonadIO, Functor, Applicative)

instance MonadTrans StreamT where
  lift f = StreamT $ lift f

instance (MonadThrow m) => MonadThrow (StreamT m) where
  monadThrow e = lift $ monadThrow e

instance (MonadResource m, MonadIO m) => MonadResource (StreamT m) where
  liftResourceT t = lift $ liftResourceT t

--------------------------------------------------------------------------------
-- Stream encoding

encodeBS :: Monad m => Conduit ByteString m ByteString 
encodeBS = awaitForever $ \bs -> do
  yield $ BS.pack (varint $ BS.length bs)
  mapM_ yield $ blocks bs
 where
  blocks bs | BS.null bs = []
            | otherwise  =
              let (f,r) = BS.splitAt 4096 bs
               in f : blocks r

encodeLazyBS :: Monad m => Conduit (Int, BL.ByteString) m ByteString
encodeLazyBS = awaitForever $ \(l,bs) -> do
  yield $ BS.pack (varint l)
  mapM_ yield $ BL.toChunks bs

--------------------------------------------------------------------------------
-- Stream decoding

-- | Get the next package from the stream (whether it's a single 'BL.ByteString' or
-- a list)
decodeCondBlock :: MonadResource m => Conduit ByteString m BL.ByteString
decodeCondBlock = do
  h <- decodeHeader
  case h of
       VarInt l     -> single l
       ConduitSTART -> list
       EndOfInput   -> return ()
       _            -> monadThrow $ UnexpectedHeader h
 where
  single l = CB.take l >>= yield

  list = do
    h <- decodeHeader
    case h of
         VarInt l   -> single l >> list
         ConduitEND -> return ()
         _          -> monadThrow $ UnexpectedHeader h
