{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE StandaloneDeriving         #-}

module Cardano.Chain.Genesis.Hash
  ( GenesisHash(..)
  )
where

import Control.DeepSeq (NFData)

import Cardano.Prelude

import Cardano.Binary (Raw, FromCBOR, ToCBOR)
import Cardano.Crypto.Hashing (Hash)

newtype GenesisHash = GenesisHash
  { unGenesisHash :: Hash Raw
  } deriving (Eq, Generic, NFData, FromCBOR, ToCBOR, NoUnexpectedThunks)

deriving instance Show GenesisHash
