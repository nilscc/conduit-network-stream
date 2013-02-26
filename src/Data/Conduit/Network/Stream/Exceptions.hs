{-# LANGUAGE DeriveDataTypeable #-}

module Data.Conduit.Network.Stream.Exceptions
  ( StreamException (..)
  , Header (..)
  ) where

import Control.Exception (Exception)
import Data.Typeable

import Data.Conduit.Network.Stream.Header

data StreamException
  = UnexpectedHeader Header
  | ClosedStream
  deriving (Show, Typeable)

instance Exception StreamException
