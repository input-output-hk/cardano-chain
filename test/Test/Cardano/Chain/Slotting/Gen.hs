{-# LANGUAGE OverloadedStrings #-}

module Test.Cardano.Chain.Slotting.Gen
       ( genEpochIndex
       , genEpochSlottingData
       , genFlatSlotId
       , genLocalSlotIndex
       , genSlotCount
       , genSlotId
       , genSlottingData
       , feedPMEpochSlots
       ) where

import           Cardano.Prelude
import           Test.Cardano.Prelude

import qualified Data.Map.Strict as Map
import           Formatting (build, sformat, (%))

import           Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import           Cardano.Chain.Slotting (EpochIndex (..),
                     EpochSlottingData (..), FlatSlotId, LocalSlotIndex,
                     SlotCount (..), SlotId (..), SlottingData,
                     createSlottingDataUnsafe, getSlotIndex,
                     localSlotIndexMaxBound, localSlotIndexMinBound,
                     mkLocalSlotIndex)
import           Cardano.Crypto (ProtocolMagic)

import           Test.Cardano.Crypto.Gen (genProtocolMagic)


genEpochIndex :: Gen EpochIndex
genEpochIndex = EpochIndex <$> Gen.word64 Range.constantBounded

genEpochSlottingData :: Gen EpochSlottingData
genEpochSlottingData = EpochSlottingData <$> genNominalDiffTime <*> genNominalDiffTime

genFlatSlotId :: Gen FlatSlotId
genFlatSlotId = Gen.word64 Range.constantBounded

genLocalSlotIndex :: SlotCount -> Gen LocalSlotIndex
genLocalSlotIndex epochSlots = mkLocalSlotIndex'
  <$> Gen.word16 (Range.constant lb ub)
 where
  lb = getSlotIndex localSlotIndexMinBound
  ub = getSlotIndex (localSlotIndexMaxBound epochSlots)
  mkLocalSlotIndex' slot = case mkLocalSlotIndex epochSlots slot of
    Left err -> error $ sformat
      ("The impossible happened in genLocalSlotIndex: " % build)
      err
    Right lsi -> lsi

genSlotCount :: Gen SlotCount
genSlotCount = SlotCount <$> Gen.word64 Range.constantBounded

genSlotId :: SlotCount -> Gen SlotId
genSlotId epochSlots =
    SlotId <$> genEpochIndex <*> genLocalSlotIndex epochSlots

genSlottingData :: Gen SlottingData
genSlottingData = createSlottingDataUnsafe <$> do
    mapSize <- Gen.int $ Range.linear 2 10
    epochSlottingDatas <- Gen.list (Range.singleton mapSize) genEpochSlottingData
    pure $ Map.fromList $ zip [0..fromIntegral mapSize - 1] epochSlottingDatas

feedPMEpochSlots :: (ProtocolMagic -> SlotCount -> Gen a) -> Gen a
feedPMEpochSlots genA = do
    pm         <- genProtocolMagic
    epochSlots <- genSlotCount
    genA pm epochSlots
