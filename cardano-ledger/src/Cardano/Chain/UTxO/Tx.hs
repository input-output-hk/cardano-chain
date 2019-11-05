{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NamedFieldPuns     #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE PatternSynonyms    #-}
{-# LANGUAGE TypeApplications   #-}

module Cardano.Chain.UTxO.Tx
  ( Tx(txInputs, txOutputs, txAttributes, txSerialized)
  , pattern Tx
  , txF
  , TxId
  , TxAttributes
  , TxIn(..)
  , TxOut(..)
  )
where

import Cardano.Prelude

import Formatting (Format, bprint, build, builder, int)
import qualified Formatting.Buildable as B

import Cardano.Binary
  ( Case(..)
  , DecoderError(DecoderErrorUnknownTag)
  , FromCBOR(..)
  , FromCBORAnnotated(..)
  , ToCBOR(..)
  , encodeListLen
  , encodePreEncoded
  , enforceSize
  , serializeEncoding'
  , szCases
  , withSlice'
  )
import Cardano.Chain.Common.CBOR
  (encodeKnownCborDataItem, knownCborDataItemSizeExpr, decodeKnownCborDataItem)
import Cardano.Chain.Common
  ( Address(..)
  , Lovelace
  , lovelaceF
  )
import Cardano.Chain.Common.Attributes (Attributes, attributesAreKnown)
import Cardano.Crypto (Hash, hash, shortHashF)


--------------------------------------------------------------------------------
-- Tx
--------------------------------------------------------------------------------

pattern Tx :: NonEmpty TxIn -> NonEmpty TxOut -> TxAttributes -> Tx
pattern Tx{txInputs, txOutputs, txAttributes} <-
   Tx' txInputs txOutputs txAttributes _
  where
    Tx txin txout txattr =
      let bytes = serializeEncoding' $
            encodeListLen 3
              <> toCBOR txin
              <> toCBOR txout
              <> toCBOR txattr
      in Tx' txin txout txattr bytes

-- | Transaction
--
--   NB: transaction witnesses are stored separately
data Tx = Tx'
  { txInputs'    :: !(NonEmpty TxIn)
  -- ^ Inputs of transaction.
  , txOutputs'   :: !(NonEmpty TxOut)
  -- ^ Outputs of transaction.
  , txAttributes':: !TxAttributes
  -- ^ Attributes of transaction
  , txSerialized :: ByteString
  } deriving (Eq, Ord, Generic, Show)
    deriving anyclass NFData

instance B.Buildable Tx where
  build tx = bprint
    ( "Tx "
    . build
    . " with inputs "
    . listJson
    . ", outputs: "
    . listJson
    . builder
    )
    (hash tx)
    (txInputs tx)
    (txOutputs tx)
    attrsBuilder
   where
    attrs = txAttributes tx
    attrsBuilder
      | attributesAreKnown attrs = mempty
      | otherwise                = bprint (", attributes: " . build) attrs

instance ToCBOR Tx where
  toCBOR = encodePreEncoded . txSerialized

  encodedSizeExpr size pxy =
    1 + size (txInputs <$> pxy) + size (txOutputs <$> pxy) + size
      (txAttributes <$> pxy)

instance FromCBORAnnotated Tx where
  fromCBORAnnotated' = withSlice' . lift $
    Tx' <$ enforceSize "Tx" 3
      <*> fromCBOR
      <*> fromCBOR
      <*> fromCBOR

-- | Specialized formatter for 'Tx'
txF :: Format r (Tx -> r)
txF = build


--------------------------------------------------------------------------------
-- TxId
--------------------------------------------------------------------------------

-- | Represents transaction identifier as 'Hash' of 'Tx'
type TxId = Hash Tx


--------------------------------------------------------------------------------
-- TxAttributes
--------------------------------------------------------------------------------

-- | Represents transaction attributes: map from 1-byte integer to
--   arbitrary-type value. To be used for extending transaction with new fields
--   via softfork.
type TxAttributes = Attributes ()


--------------------------------------------------------------------------------
-- TxIn
--------------------------------------------------------------------------------

-- | Transaction arbitrary input
data TxIn
  -- | TxId = Which transaction's output is used
  -- | Word32 = Index of the output in transaction's outputs
  = TxInUtxo TxId Word32
  deriving (Eq, Ord, Generic, Show)
  deriving anyclass NFData

instance B.Buildable TxIn where
  build (TxInUtxo txInHash txInIndex) =
    bprint ("TxInUtxo " . shortHashF . " #" . int) txInHash txInIndex

instance ToCBOR TxIn where
  toCBOR (TxInUtxo txInHash txInIndex) =
    encodeListLen 2 <> toCBOR (0 :: Word8) <> encodeKnownCborDataItem
      (txInHash, txInIndex)

  encodedSizeExpr size _ = 2 + knownCborDataItemSizeExpr
    (szCases [Case "TxInUtxo" $ size $ Proxy @(TxId, Word32)])

instance FromCBOR TxIn where
  fromCBOR = do
    enforceSize "TxIn" 2
    tag <- fromCBOR @Word8
    case tag of
      0 -> uncurry TxInUtxo <$> decodeKnownCborDataItem
      _ -> cborError $ DecoderErrorUnknownTag "TxIn" tag

instance HeapWords TxIn where
  heapWords (TxInUtxo txid w32) = heapWords2 txid w32


--------------------------------------------------------------------------------
-- TxOut
--------------------------------------------------------------------------------

-- | Transaction output
data TxOut = TxOut
  { txOutAddress :: !Address
  , txOutValue   :: !Lovelace
  } deriving (Eq, Ord, Generic, Show)
    deriving anyclass NFData

instance B.Buildable TxOut where
  build txOut = bprint
    ("TxOut " . lovelaceF . " -> " . build)
    (txOutValue txOut)
    (txOutAddress txOut)

instance ToCBOR TxOut where
  toCBOR txOut =
    encodeListLen 2 <> toCBOR (txOutAddress txOut) <> toCBOR (txOutValue txOut)

  encodedSizeExpr size pxy =
    1 + size (txOutAddress <$> pxy) + size (txOutValue <$> pxy)

instance FromCBOR TxOut where
  fromCBOR = do
    enforceSize "TxOut" 2
    TxOut <$> fromCBOR <*> fromCBOR

instance HeapWords TxOut where
  heapWords (TxOut address _) = 3 + heapWords address
