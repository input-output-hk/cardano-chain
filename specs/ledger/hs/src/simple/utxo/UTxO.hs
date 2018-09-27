{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DerivingVia #-}
module UTxO where

import           Crypto.Hash (Digest, SHA256)
import qualified Data.ByteArray        as BA
import Data.Monoid (Sum(..))
import           Numeric.Natural       (Natural)

type Hash = Digest SHA256

newtype Coin = Coin Natural
  deriving (Show, Eq, Ord)
  deriving (Semigroup, Monoid) via (Sum Natural)

-- |The address of a transaction output, used to identify the owner.
newtype Addr = Addr Hash
  deriving (Show, Eq, Ord)
