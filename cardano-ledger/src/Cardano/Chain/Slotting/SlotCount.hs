{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Cardano.Chain.Slotting.SlotCount
  ( SlotCount(..)
  )
where

import Cardano.Prelude
import Cardano.Prelude.CanonicalExamples.Orphans ()

import Formatting.Buildable (Buildable)

import Cardano.Binary (FromCBOR, ToCBOR)


-- | A number of slots
newtype SlotCount = SlotCount
  { unSlotCount :: Word64
  } deriving stock (Read, Show, Generic)
    deriving newtype (Eq, Ord, Buildable, ToCBOR, FromCBOR, CanonicalExamples)
    deriving anyclass (NFData)
