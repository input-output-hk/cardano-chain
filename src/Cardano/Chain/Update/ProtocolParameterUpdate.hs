{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TypeApplications   #-}

module Cardano.Chain.Update.ProtocolParameterUpdate
  ( ProtocolParameterUpdate(..)
  , applyPPU
  )
where

import Cardano.Prelude

import Data.Text.Lazy.Builder (Builder)
import Data.Time (NominalDiffTime)
import Formatting (Format, bprint, build, bytes, int, later, shortest)
import qualified Formatting.Buildable as B

import Cardano.Binary.Class (Bi(..), encodeListLen, enforceSize)
import Cardano.Chain.Common (LovelacePortion, ScriptVersion, TxFeePolicy)
import Cardano.Chain.Slotting (EpochIndex, FlatSlotId)
import Cardano.Chain.Update.ProtocolParameters (ProtocolParameters(..))
import Cardano.Chain.Update.SoftforkRule (SoftforkRule)


-- | Data which represents modifications of block (aka protocol) version
data ProtocolParameterUpdate = ProtocolParameterUpdate
  { ppuScriptVersion     :: !(Maybe ScriptVersion)
  , ppuSlotDuration      :: !(Maybe NominalDiffTime)
  , ppuMaxBlockSize      :: !(Maybe Natural)
  , ppuMaxHeaderSize     :: !(Maybe Natural)
  , ppuMaxTxSize         :: !(Maybe Natural)
  , ppuMaxProposalSize   :: !(Maybe Natural)
  , ppuMpcThd            :: !(Maybe LovelacePortion)
  , ppuHeavyDelThd       :: !(Maybe LovelacePortion)
  , ppuUpdateVoteThd     :: !(Maybe LovelacePortion)
  , ppuUpdateProposalThd :: !(Maybe LovelacePortion)
  , ppuUpdateImplicit    :: !(Maybe FlatSlotId)
  , ppuSoftforkRule      :: !(Maybe SoftforkRule)
  , ppuTxFeePolicy       :: !(Maybe TxFeePolicy)
  , ppuUnlockStakeEpoch  :: !(Maybe EpochIndex)
  } deriving (Show, Eq, Ord, Generic)
    deriving anyclass NFData

instance B.Buildable ProtocolParameterUpdate where
  build ppu = bprint
    ( "{ script version: " . bmodifier build
    . ", slot duration: " . bmodifier build
    . ", block size limit: " . bmodifier bytes'
    . ", header size limit: " . bmodifier bytes'
    . ", tx size limit: " . bmodifier bytes'
    . ", proposal size limit: " . bmodifier bytes'
    . ", mpc threshold: " . bmodifier build
    . ", heavyweight delegation threshold: " . bmodifier build
    . ", update vote threshold: " . bmodifier build
    . ", update proposal threshold: " . bmodifier build
    . ", update implicit period (slots): " . bmodifier int
    . ", softfork rule: " . bmodifier build
    . ", tx fee policy: " . bmodifier build
    . ", unlock stake epoch: " . bmodifier build
    . " }"
    )
    (ppuScriptVersion ppu)
    (ppuSlotDuration ppu)
    (ppuMaxBlockSize ppu)
    (ppuMaxHeaderSize ppu)
    (ppuMaxTxSize ppu)
    (ppuMaxProposalSize ppu)
    (ppuMpcThd ppu)
    (ppuHeavyDelThd ppu)
    (ppuUpdateVoteThd ppu)
    (ppuUpdateProposalThd ppu)
    (ppuUpdateImplicit ppu)
    (ppuSoftforkRule ppu)
    (ppuTxFeePolicy ppu)
    (ppuUnlockStakeEpoch ppu)
   where
    bmodifier :: Format Builder (a -> Builder) -> Format r (Maybe a -> r)
    bmodifier b = later $ maybe "no change" (bprint b)

    bytes' :: Format r (Natural -> r)
    bytes' = bytes (shortest @Double)

instance Bi ProtocolParameterUpdate where
  encode ppu =
    encodeListLen 14
      <> encode (ppuScriptVersion ppu)
      <> encode (ppuSlotDuration ppu)
      <> encode (ppuMaxBlockSize ppu)
      <> encode (ppuMaxHeaderSize ppu)
      <> encode (ppuMaxTxSize ppu)
      <> encode (ppuMaxProposalSize ppu)
      <> encode (ppuMpcThd ppu)
      <> encode (ppuHeavyDelThd ppu)
      <> encode (ppuUpdateVoteThd ppu)
      <> encode (ppuUpdateProposalThd ppu)
      <> encode (ppuUpdateImplicit ppu)
      <> encode (ppuSoftforkRule ppu)
      <> encode (ppuTxFeePolicy ppu)
      <> encode (ppuUnlockStakeEpoch ppu)

  decode = do
    enforceSize "ProtocolParameterUpdate" 14
    ProtocolParameterUpdate
      <$> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode

-- | Apply 'ProtocolParameterUpdate' to 'ProtocolParameters'
applyPPU :: ProtocolParameterUpdate -> ProtocolParameters -> ProtocolParameters
applyPPU ppu pp = ProtocolParameters
  { ppScriptVersion     = fromMaybe (ppScriptVersion pp) (ppuScriptVersion ppu)
  , ppSlotDuration      = fromMaybe (ppSlotDuration pp) (ppuSlotDuration ppu)
  , ppMaxBlockSize      = fromMaybe (ppMaxBlockSize pp) (ppuMaxBlockSize ppu)
  , ppMaxHeaderSize     = fromMaybe (ppMaxHeaderSize pp) (ppuMaxHeaderSize ppu)
  , ppMaxTxSize         = fromMaybe (ppMaxTxSize pp) (ppuMaxTxSize ppu)
  , ppMaxProposalSize   = fromMaybe
    (ppMaxProposalSize pp)
    (ppuMaxProposalSize ppu)
  , ppMpcThd            = fromMaybe (ppMpcThd pp) (ppuMpcThd ppu)
  , ppHeavyDelThd       = fromMaybe (ppHeavyDelThd pp) (ppuHeavyDelThd ppu)
  , ppUpdateVoteThd     = fromMaybe (ppUpdateVoteThd pp) (ppuUpdateVoteThd ppu)
  , ppUpdateProposalThd = fromMaybe
    (ppUpdateProposalThd pp)
    (ppuUpdateProposalThd ppu)
  , ppUpdateImplicit = fromMaybe (ppUpdateImplicit pp) (ppuUpdateImplicit ppu)
  , ppSoftforkRule      = fromMaybe (ppSoftforkRule pp) (ppuSoftforkRule ppu)
  , ppTxFeePolicy       = fromMaybe (ppTxFeePolicy pp) (ppuTxFeePolicy ppu)
  , ppUnlockStakeEpoch  = fromMaybe
    (ppUnlockStakeEpoch pp)
    (ppuUnlockStakeEpoch ppu)
  }