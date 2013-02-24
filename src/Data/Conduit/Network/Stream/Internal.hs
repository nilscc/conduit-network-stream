{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Data.Conduit.Network.Stream.Internal where

import Control.Applicative
import Control.Monad.Trans
import Control.Monad.Trans.Resource
import Data.Conduit
import Data.ByteString (ByteString)

import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BL

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

encodeBS :: Monad m => Conduit ByteString (Stream m) ByteString 
encodeBS = awaitForever $ \bs -> do
  yield $ BS.pack (varint $ BS.length bs)
  mapM_ yield $ blocks bs
 where
  blocks bs | BS.null bs = []
            | otherwise  =
              let (f,r) = BS.splitAt 4096 bs
               in f : blocks r

encodeLazyBS :: Monad m => Conduit (Int, BL.ByteString) (Stream m) ByteString
encodeLazyBS = awaitForever $ \(l,bs) -> do
  yield $ BS.pack (varint l)
  mapM_ yield $ BL.toChunks bs
