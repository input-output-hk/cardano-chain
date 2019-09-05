{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE NamedFieldPuns     #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE PatternSynonyms    #-}
{-# LANGUAGE TypeFamilies       #-}

module Cardano.Chain.Update.Payload
  ( Payload(..)
  , pattern Payload
  )
where

import Cardano.Prelude

import Formatting (bprint)
import qualified Formatting.Buildable as B

import Cardano.Binary
  ( Annotated(..)
  , ByteSpan
  , Decoded(..)
  , FromCBOR(..)
  , FromCBORAnnotated(..)
  , ToCBOR(..)
  , annotatedDecoder
  , encodeListLen
  , encodePreEncoded
  , enforceSize
  , serializeEncoding'
  , withSlice'
  )
import Cardano.Chain.Update.Proposal
  ( Proposal
  , formatMaybeProposal
  )
import Cardano.Chain.Update.Vote
  ( Vote
  , formatVoteShort
  )


pattern Payload :: Maybe Proposal -> [Vote] -> Payload
pattern Payload payloadProposal payloadVotes <- Payload' {payloadProposal, payloadVotes}
  where
    Payload payloadProposal payloadVotes =
      let bytes = serializeEncoding' $
            encodeListLen 2 <> toCBOR payloadProposal <> toCBOR payloadVotes
      in Payload' payloadProposal payloadVotes bytes

-- | Update System payload
data Payload = Payload'
  { payloadProposal   :: !(Maybe Proposal)
  , payloadVotes      :: ![Vote]
  , payloadSerialized :: ByteString
  } deriving (Eq, Show, Generic)
    deriving anyclass NFData

instance Decoded Payload where
  type BaseType Payload = Payload
  recoverBytes = payloadSerialized

instance B.Buildable Payload where
  build p
    | null (payloadVotes p)
    = formatMaybeProposal (payloadProposal p) <> ", no votes"
    | otherwise
    = formatMaybeProposal (payloadProposal p) <> bprint
      ("\n    votes: " . listJson)
      (map formatVoteShort (payloadVotes p))

instance ToCBOR Payload where
  toCBOR = encodePreEncoded . payloadSerialized

instance FromCBORAnnotated Payload where
  fromCBORAnnotated' = withSlice' $
    Payload' <$ lift (enforceSize "Update.Payload" 2)
      <*> fromCBORAnnotated'
      <*> fromCBORAnnotated'
