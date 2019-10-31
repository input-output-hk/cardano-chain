{-# LANGUAGE NamedFieldPuns     #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE TypeApplications   #-}

module Test.Cardano.Chain.Block.ValidationMode
  ( tests
  )
where

import Cardano.Prelude hiding (State, trace)
import Test.Cardano.Prelude

import Control.Lens ((^.))
import qualified Data.Bimap as BM
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Word (Word64)

import Cardano.Binary (Annotated (..))
import Cardano.Chain.Block
  ( Block (..)
  , AHeader (..)
  , BlockValidationMode (..)
  , Proof (..)
  , blockProof
  , initialChainValidationState
  , updateBlock
  )
import Cardano.Chain.Delegation as Delegation
import Cardano.Chain.UTxO (TxProof)
import Cardano.Chain.ValidationMode
  (ValidationMode (..), fromBlockValidationMode)
import Cardano.Crypto (Hash)

import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import qualified Cardano.Spec.Chain.STS.Block as Abstract
import qualified Cardano.Spec.Chain.STS.Rule.Chain as Abstract
import Cardano.Spec.Chain.STS.Rule.Chain (CHAIN)
import Cardano.Ledger.Spec.STS.UTXOWS (UTXOWS)
import Cardano.Ledger.Spec.STS.UTXO (UTxOEnv (..), UTxOState (..))
import Control.State.Transition
import Control.State.Transition.Generator (trace)
import qualified Control.State.Transition.Trace as Trace
import qualified Ledger.Core as Abstract
import Ledger.Delegation
  ( ADELEGS
  , DELEG
  , DIState (..)
  , DState (..)
  )
import Ledger.GlobalParams (lovelaceCap)
import qualified Ledger.UTxO as Abstract

import qualified Test.Cardano.Chain.Delegation.Gen as Delegation
import Test.Cardano.Chain.Elaboration.Block
  ( transactionIds
  , abEnvToCfg
  , rcDCert
  , elaborate
  )
import qualified Test.Cardano.Chain.Update.Gen as Update
import Test.Cardano.Chain.UTxO.Gen (genTxProof)
import Test.Cardano.Chain.UTxO.Model (elaborateInitialUTxO)
import Test.Cardano.Crypto.Gen (feedPM, genAbstractHash)
import Test.Options (TSGroup, TSProperty, withTestsTS)

--------------------------------------------------------------------------------
-- BlockValidationMode Properties
--------------------------------------------------------------------------------

-- | Property: When calling 'updateBlock' given a valid 'Block', validation
-- should pass in all 'BlockValidationMode's.
ts_prop_updateBlock_Valid :: TSProperty
ts_prop_updateBlock_Valid =
  withTestsTS 100
    . property
    $ do
      let traceLength = 10 :: Word64 -- TODO: check that the @k@ value is not important
                           -- in this test, in that case we can get away with
                           -- generating small traces.
      sampleTrace <- forAll $ trace @CHAIN traceLength
      let
        lastState = Trace.lastState sampleTrace
        chainEnv@( _currentSlot
                 , abstractInitialUTxO
                 , _allowedDelegators
                 , _protocolParamaters
                 , stableAfter
                 ) = Trace._traceEnv sampleTrace
      abstractBlock <- forAll $
        Abstract.sigGenChain
          Abstract.NoGenDelegation
          Abstract.NoGenUTxO
          Abstract.NoGenUpdate
          chainEnv
          lastState
      let config = abEnvToCfg chainEnv
          cvs = either (panic . show) (\a -> a) (initialChainValidationState config)
          (_, txIdMap) = elaborateInitialUTxO abstractInitialUTxO
          dCert = rcDCert
                    (abstractBlock ^. Abstract.bHeader . Abstract.bhIssuer)
                    stableAfter
                    lastState
      vMode <- forAll $ fromBlockValidationMode <$> genBlockValidationMode
      let (concreteBlock, _txIdMap') =
            elaborate
              mempty { transactionIds = txIdMap }
              config
              dCert
              cvs
              abstractBlock
      annotateShow concreteBlock
      updateRes <- (`runReaderT` vMode) . runExceptT $
        updateBlock config cvs concreteBlock
      case updateRes of
        Left _  -> failure
        Right _ -> success

-- | Property: When calling 'updateBlock' given a 'Block' with an invalid
-- 'Proof', 'Block' validation should only pass in the 'NoBlockValidation' mode.
-- This is because this mode does not perform any validation on the 'Block'.
ts_prop_updateBlock_InvalidProof :: TSProperty
ts_prop_updateBlock_InvalidProof =
  withTestsTS 100
    . property
    $ do
      let traceLength = 10 :: Word64
      sampleTrace <- forAll $ trace @CHAIN traceLength
      let
        chainEnv@(_, abstractInitialUTxO, _, _, stableAfter) = Trace._traceEnv sampleTrace
        lastState = Trace.lastState sampleTrace
      abstractBlock <- forAll $
        Abstract.sigGenChain
          Abstract.NoGenDelegation
          Abstract.NoGenUTxO
          Abstract.NoGenUpdate
          chainEnv
          lastState
      let config = abEnvToCfg chainEnv
          cvs = either (panic . show) (\a -> a) (initialChainValidationState config)
          (_, txIdMap) = elaborateInitialUTxO abstractInitialUTxO
          dCert = rcDCert (abstractBlock ^. Abstract.bHeader . Abstract.bhIssuer) stableAfter lastState
      vMode <- forAll $ fromBlockValidationMode <$> genBlockValidationMode
      let (concreteBlock, _abstractToConcreteIdMaps') =
            elaborate
              initialAbstractToConcreteIdMaps
              config
              dCert
              cvs
              abstractBlock
          initialAbstractToConcreteIdMaps = mempty { transactionIds = txIdMap }
      annotateShow concreteBlock
      invalidBlock <- forAll $ invalidateABlockProof concreteBlock
      updateRes <- (`runReaderT` vMode) . runExceptT $
        updateBlock config cvs invalidBlock
      case updateRes of
        Left _ ->
          if (blockValidationMode vMode) == BlockValidation
          then success
          else failure
        Right _ ->
          if (blockValidationMode vMode) == NoBlockValidation
          then success
          else failure

--------------------------------------------------------------------------------
-- Generators
--------------------------------------------------------------------------------

genHash :: Gen Abstract.Hash
genHash = Abstract.Hash . Just <$> Gen.int Range.constantBounded

genBlockValidationMode :: Gen BlockValidationMode
genBlockValidationMode = Gen.element [BlockValidation, NoBlockValidation]

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

createInitialUTxOState
  :: Environment UTXOWS
  -> State UTXOWS
createInitialUTxOState utxoEnv =
  UTxOState{ utxo = utxo0, reserves = lovelaceCap - Abstract.balance utxo0 }
 where
  UTxOEnv
    { utxo0
    } = utxoEnv

createInitialDState
  :: Environment ADELEGS
  -> State ADELEGS
createInitialDState env =
  DState
    { _dStateDelegationMap = BM.fromList $
        map (\vkg@(Abstract.VKeyGenesis key) -> (vkg, key))
            (S.toList env)
    , _dStateLastDelegation = M.fromSet (const (Abstract.Slot 0)) env
    }

createInitialDIState
  :: State ADELEGS
  -> State DELEG
createInitialDIState dState =
  DIState
    { _dIStateDelegationMap = _dStateDelegationMap dState
    , _dIStateLastDelegation = _dStateLastDelegation dState
    , _dIStateScheduledDelegations = []
    , _dIStateKeyEpochDelegations = S.empty
    }

modifyAHeader
  :: (AHeader ByteString -> AHeader ByteString)
  -> Block
  -> Block
modifyAHeader ahModifier ab =
  ab { blockHeader = ahModifier (blockHeader ab) }

modifyAProof
  :: (Annotated Proof ByteString -> Annotated Proof ByteString)
  -> Block
  -> Block
modifyAProof apModifier ab =
  modifyAHeader ahModifier ab
 where
  ahModifier :: AHeader ByteString -> AHeader ByteString
  ahModifier ah = ah { aHeaderProof = apModifier (aHeaderProof ah) }

modifyDelegationProof
  :: (Hash Delegation.Payload -> Hash Delegation.Payload)
  -> Block
  -> Block
modifyDelegationProof dpModifier ab =
  modifyAProof apModifier ab
 where
  apModifier :: Annotated Proof ByteString -> Annotated Proof ByteString
  apModifier (Annotated p bs) = Annotated
    p { proofDelegation = dpModifier (proofDelegation p) }
    bs

modifyTxProof
  :: (TxProof -> TxProof)
  -> Block
  -> Block
modifyTxProof tpModifier ab =
  modifyAProof apModifier ab
 where
  apModifier :: Annotated Proof ByteString -> Annotated Proof ByteString
  apModifier (Annotated p bs) = Annotated
    p { proofUTxO = tpModifier (proofUTxO p) }
    bs

invalidateABlockProof
  :: Block
  -> Gen Block
invalidateABlockProof ab =
  -- 'Gen.filter' to ensure we don't generate a valid proof
  Gen.filter (\x -> blockProof x /= blockProof ab) $ do
    txProof  <- Gen.choice
      [ pure $ (proofUTxO . blockProof) ab
      , feedPM genTxProof
      ]
    dlgProof <- Gen.choice
      [ pure $ (proofDelegation . blockProof) ab
      , genAbstractHash (feedPM Delegation.genPayload)
      ]
    updProof <- Gen.choice
      [ pure $ proofUpdate (blockProof ab)
      , feedPM Update.genProof
      ]
    pure $ modifyAProof
      (\(Annotated p bs) -> Annotated
        (p
          { proofUTxO = txProof
          , proofDelegation = dlgProof
          , proofUpdate = updProof
          }
        )
        bs
      )
      ab

--------------------------------------------------------------------------------
-- Main Test Export
--------------------------------------------------------------------------------

tests :: TSGroup
tests = $$discoverPropArg
