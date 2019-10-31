{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE PatternSynonyms  #-}

{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}

module Test.Cardano.Chain.UTxO.Example
  ( exampleTxAux
  , exampleTxAux1
  , exampleTxId
  , exampleTxInList
  , exampleTxInUtxo
  , exampleTxPayload
  , exampleTxPayload1
  , exampleTxProof
  , exampleTxOut
  , exampleTxOut1
  , exampleTxOutList
  , exampleTxSig
  , exampleTxSigData
  , exampleTxWitness
  , exampleRedeemSignature
  , exampleHashTx
  )
where

import Cardano.Prelude

import Data.Coerce (coerce)
import Data.List.NonEmpty (fromList)
import Data.Maybe (fromJust)
import qualified Data.Vector as V

import Cardano.Chain.Common
  ( NetworkMagic(..)
  , makeVerKeyAddress
  , mkAttributes
  , mkKnownLovelace
  , mkMerkleTree
  , mtRoot
  )
import Cardano.Chain.UTxO
  ( Tx
  , pattern Tx
  , TxAux(..)
  , TxId
  , TxIn(..)
  , TxInWitness(..)
  , TxOut(..)
  , TxPayload(..)
  , TxProof(..)
  , TxSig
  , TxSigData(..)
  , TxWitness
  , pattern TxWitness
  )
import Cardano.Crypto
  ( AbstractHash(..)
  , Hash
  , ProtocolMagicId(..)
  , VerificationKey(..)
  , RedeemSignature
  , SignTag(..)
  , hash
  , redeemDeterministicKeyGen
  , redeemSign
  , sign
  )
import qualified Cardano.Crypto.Wallet as CC

import Test.Cardano.Crypto.CBOR (getBytes)
import Test.Cardano.Crypto.Example (exampleVerificationKey, exampleSigningKey)


exampleTxAux :: TxAux
exampleTxAux = TxAux tx exampleTxWitness
  where tx = Tx exampleTxInList exampleTxOutList (mkAttributes ())

exampleTxAux1 :: TxAux
exampleTxAux1 = TxAux tx exampleTxWitness
  where tx = Tx exampleTxInList1 exampleTxOutList1 (mkAttributes ())

exampleTxId :: TxId
exampleTxId = exampleHashTx

exampleTxInList :: (NonEmpty TxIn)
exampleTxInList = fromList [exampleTxInUtxo]

exampleTxInList1 :: (NonEmpty TxIn)
exampleTxInList1 = fromList [exampleTxInUtxo, exampleTxInUtxo1]

exampleTxInUtxo :: TxIn
exampleTxInUtxo = TxInUtxo exampleHashTx 47 -- TODO: loop here

exampleTxInUtxo1 :: TxIn
exampleTxInUtxo1 = TxInUtxo exampleHashTx 74

exampleTxOut :: TxOut
exampleTxOut = TxOut (makeVerKeyAddress NetworkMainOrStage vkey)
                     (mkKnownLovelace @47)
  where Right vkey = VerificationKey <$> CC.xpub (getBytes 0 64)

exampleTxOut1 :: TxOut
exampleTxOut1 = TxOut (makeVerKeyAddress (NetworkTestnet 74) vkey) (mkKnownLovelace @47)
  where Right vkey = VerificationKey <$> CC.xpub (getBytes 0 64)

exampleTxOutList :: (NonEmpty TxOut)
exampleTxOutList = fromList [exampleTxOut]

exampleTxOutList1 :: (NonEmpty TxOut)
exampleTxOutList1 = fromList [exampleTxOut, exampleTxOut1]

exampleTxPayload :: TxPayload
exampleTxPayload = TxPayload [exampleTxAux]

exampleTxPayload1 :: TxPayload
exampleTxPayload1 = TxPayload [exampleTxAux, exampleTxAux1]

exampleTxProof :: TxProof
exampleTxProof = TxProof 32 mroot hashWit
 where
  mroot = mtRoot $ mkMerkleTree
    [(Tx exampleTxInList exampleTxOutList (mkAttributes ()))]
  hashWit = hash $ TxWitness <$> [(V.fromList [(VKWitness exampleVerificationKey exampleTxSig)])]

exampleTxSig :: TxSig
exampleTxSig =
  sign (ProtocolMagicId 0) SignForTestingOnly exampleSigningKey exampleTxSigData

exampleTxSigData :: TxSigData
exampleTxSigData = TxSigData exampleHashTx

exampleTxWitness :: TxWitness
exampleTxWitness = TxWitness $ V.fromList [(VKWitness exampleVerificationKey exampleTxSig)]

exampleRedeemSignature :: RedeemSignature TxSigData
exampleRedeemSignature = redeemSign
  (ProtocolMagicId 0)
  SignForTestingOnly
  rsk
  exampleTxSigData
  where rsk = fromJust (snd <$> redeemDeterministicKeyGen (getBytes 0 32))

exampleHashTx :: Hash Tx
exampleHashTx = coerce (hash "golden" :: Hash Text)
