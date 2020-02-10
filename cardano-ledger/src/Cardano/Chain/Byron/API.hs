{-# LANGUAGE DeriveAnyClass           #-}
{-# LANGUAGE DeriveFunctor            #-}
{-# LANGUAGE DeriveGeneric            #-}
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE LambdaCase               #-}
{-# LANGUAGE NamedFieldPuns           #-}
{-# LANGUAGE OverloadedStrings        #-}
{-# LANGUAGE RankNTypes               #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE TypeApplications         #-}
{-# LANGUAGE TypeFamilies             #-}

-- | Auxiliary definitions to make working with the Byron ledger easier
module Cardano.Chain.Byron.API (
    -- * Extract info from genesis config
    allowedDelegators
    -- * Extract info from chain state
  , getDelegationMap
  , getProtocolParams
  , getScheduledDelegations
  , getMaxBlockSize
    -- * Applying blocks
  , applyChainTick
  , validateBlock
  , validateBoundary
  , previewDelegationMap
    -- * Applying transactions
  , ApplyMempoolPayloadErr(..)
  , applyMempoolPayload
  , mempoolPayloadRecoverBytes
  , mempoolPayloadReencode
    -- * Annotations
  , reAnnotateBlock
  , reAnnotateBoundary
  , reAnnotateUsing
    -- * Headers
  , abobMatchesBody
  ) where

import           Codec.CBOR.Decoding (Decoder)
import qualified Codec.CBOR.Decoding as CBOR
import qualified Codec.CBOR.Encoding as CBOR
import qualified Codec.CBOR.Read as CBOR
import qualified Codec.CBOR.Write as CBOR
import           Control.Monad.Except
import           Control.Monad.Reader
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as Lazy
import           Data.Either (isRight)
import           Data.Sequence (Seq)
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as T
import           Data.Word

import           Cardano.Binary
import           Cardano.Crypto.ProtocolMagic
import           Cardano.Prelude

import qualified Cardano.Chain.Block as CC
import qualified Cardano.Chain.Common as CC
import qualified Cardano.Chain.Delegation as Delegation
import qualified Cardano.Chain.Delegation.Validation.Interface as D.Iface
import qualified Cardano.Chain.Delegation.Validation.Scheduling as D.Sched
import qualified Cardano.Chain.Genesis as Gen
import qualified Cardano.Chain.MempoolPayload as CC
import qualified Cardano.Chain.Slotting as CC
import qualified Cardano.Chain.Update as Update
import qualified Cardano.Chain.Update.Validation.Interface as U.Iface
import qualified Cardano.Chain.UTxO as Utxo
import qualified Cardano.Chain.ValidationMode as CC

{-------------------------------------------------------------------------------
  Extract info from genesis config
-------------------------------------------------------------------------------}

allowedDelegators :: Gen.Config -> Set CC.KeyHash
allowedDelegators =
      Gen.unGenesisKeyHashes
    . Gen.configGenesisKeyHashes

{-------------------------------------------------------------------------------
  Extract info from chain state
-------------------------------------------------------------------------------}

getDelegationMap :: CC.ChainValidationState -> Delegation.Map
getDelegationMap =
      D.Iface.delegationMap
    . CC.cvsDelegationState

getProtocolParams :: CC.ChainValidationState -> Update.ProtocolParameters
getProtocolParams =
      U.Iface.adoptedProtocolParameters
    . CC.cvsUpdateState

getScheduledDelegations :: CC.ChainValidationState
                        -> Seq D.Sched.ScheduledDelegation
getScheduledDelegations =
      D.Sched.scheduledDelegations
    . D.Iface.schedulingState
    . CC.cvsDelegationState

getMaxBlockSize :: CC.ChainValidationState -> Word32
getMaxBlockSize =
      fromIntegral
    . Update.ppMaxBlockSize
    . getProtocolParams

{-------------------------------------------------------------------------------
  Update parts of the chain state
-------------------------------------------------------------------------------}

setUTxO :: Utxo.UTxO
        -> CC.ChainValidationState -> CC.ChainValidationState
setUTxO newUTxO cvs = cvs { CC.cvsUtxo = newUTxO }

setDelegationState :: D.Iface.State
                   -> CC.ChainValidationState -> CC.ChainValidationState
setDelegationState newDlg cvs = cvs { CC.cvsDelegationState = newDlg }

setUpdateState :: U.Iface.State
               -> CC.ChainValidationState -> CC.ChainValidationState
setUpdateState newUpdate cvs = cvs { CC.cvsUpdateState = newUpdate }

{-------------------------------------------------------------------------------
  Applying blocks
-------------------------------------------------------------------------------}

mkEpochEnvironment :: Gen.Config
                   -> CC.ChainValidationState
                   -> CC.EpochEnvironment
mkEpochEnvironment cfg cvs = CC.EpochEnvironment {
      CC.protocolMagic     = reAnnotateMagicId $
                               Gen.configProtocolMagicId cfg
    , CC.k                 = Gen.configK cfg
    , CC.allowedDelegators = allowedDelegators cfg
    , CC.delegationMap     = delegationMap
      -- The 'currentEpoch' required by the epoch environment is the /old/
      -- epoch (i.e., the one in the ledger state), so that we can verify that
      -- the new epoch indeed is after the old.
    , CC.currentEpoch      = CC.slotNumberEpoch
                               (Gen.configEpochSlots cfg)
                               (CC.cvsLastSlot cvs)
    }
  where
    delegationMap :: Delegation.Map
    delegationMap = D.Iface.delegationMap $ CC.cvsDelegationState cvs

mkBodyState :: CC.ChainValidationState -> CC.BodyState
mkBodyState cvs = CC.BodyState {
      CC.utxo            = CC.cvsUtxo            cvs
    , CC.updateState     = CC.cvsUpdateState     cvs
    , CC.delegationState = CC.cvsDelegationState cvs
    }

-- TODO: Unlike 'mkEpochEnvironment' and 'mkDelegationEnvironment', for the
-- body processing we set 'currentEpoch' to the epoch of the block rather than
-- the current epoch (in the state). Is that deliberate?
mkBodyEnvironment :: Gen.Config
                  -> Update.ProtocolParameters
                  -> CC.SlotNumber
                  -> CC.BodyEnvironment
mkBodyEnvironment cfg params slotNo = CC.BodyEnvironment {
      CC.protocolMagic      = reAnnotateMagic $ Gen.configProtocolMagic cfg
    , CC.utxoConfiguration  = Gen.configUTxOConfiguration cfg
    , CC.k                  = Gen.configK cfg
    , CC.allowedDelegators  = allowedDelegators cfg
    , CC.protocolParameters = params
      -- The 'currentEpoch' for validating a block should be the /current/
      -- epoch (that is, the epoch of the block), /not/ the old epoch
      -- (from the ledger state). This is to make sure delegation certificates
      -- are for the /next/ epoch.
    , CC.currentEpoch       = CC.slotNumberEpoch
                                (Gen.configEpochSlots cfg)
                                slotNo
    }

-- | Apply chain tick
--
-- This is the part of block processing that depends only on the slot number of
-- the block: We update
--
-- * The update state
-- * The delegation state
-- * The last applied slot number
--
-- NOTE: The spec currently only updates the update state here; this is not good
-- enough. Fortunately, updating the delegation state and slot number here
-- (currently done in body processing) is at least /conform/ spec, as these
-- updates are conform spec. See
--
-- <https://github.com/input-output-hk/cardano-ledger-specs/issues/1046>
-- <https://github.com/input-output-hk/ouroboros-network/issues/1291>
applyChainTick :: Gen.Config
               -> CC.SlotNumber
               -> CC.ChainValidationState
               -> CC.ChainValidationState
applyChainTick cfg slotNo cvs = cvs {
      CC.cvsUpdateState     = CC.epochTransition
                                (mkEpochEnvironment cfg cvs)
                                (CC.cvsUpdateState cvs)
                                slotNo
    , CC.cvsDelegationState = D.Iface.tickDelegation
                                currentEpoch
                                slotNo
                                (CC.cvsDelegationState cvs)
    }

  where
   currentEpoch = CC.slotNumberEpoch (Gen.configEpochSlots cfg) slotNo

-- | Validate header
--
-- NOTE: Header validation does not produce any state changes; the only state
-- changes arising from processing headers come from 'applyChainTick'.
validateHeader :: MonadError CC.ChainValidationError m
               => CC.ValidationMode
               -> U.Iface.State -> CC.AHeader ByteString -> m ()
validateHeader validationMode updState hdr =
    flip runReaderT validationMode $
      CC.headerIsValid updState hdr

validateBody :: MonadError CC.ChainValidationError m
             => CC.ValidationMode
             -> CC.ABlock ByteString
             -> CC.BodyEnvironment -> CC.BodyState -> m CC.BodyState
validateBody validationMode block bodyEnv bodyState =
    flip runReaderT validationMode $
      CC.updateBody bodyEnv bodyState block

validateBlock :: MonadError CC.ChainValidationError m
              => Gen.Config
              -> CC.ValidationMode
              -> CC.ABlock ByteString
              -> CC.HeaderHash
              -> CC.ChainValidationState -> m CC.ChainValidationState
validateBlock cfg validationMode block blkHash cvs = do

    -- TODO: How come this check isn't done in 'updateBlock'
    -- (but it /is/ done in 'updateChainBoundary')?
    --
    -- TODO: It could be argued that hash checking isn't part of consensus /or/
    -- the ledger. If we take that point of view serious, we should think about
    -- what that third thing is precisely and what its responsibilities are.
    validatePrevHashMatch block cvs

    validateHeader validationMode updState (CC.blockHeader block)
    bodyState' <- validateBody validationMode block bodyEnv bodyState
    return cvs {
          CC.cvsLastSlot        = CC.blockSlot block
        , CC.cvsPreviousHash    = Right $! blkHash
        , CC.cvsUtxo            = CC.utxo            bodyState'
        , CC.cvsUpdateState     = CC.updateState     bodyState'
        , CC.cvsDelegationState = CC.delegationState bodyState'
        }
  where
    updState  = CC.cvsUpdateState cvs
    bodyEnv   = mkBodyEnvironment
                  cfg
                  (getProtocolParams cvs)
                  (CC.blockSlot block)
    bodyState = mkBodyState cvs

validatePrevHashMatch :: MonadError CC.ChainValidationError m
                      => CC.ABlock ByteString
                      -> CC.ChainValidationState -> m ()
validatePrevHashMatch block cvs = do
    case ( CC.cvsPreviousHash cvs
         , unAnnotated $ CC.aHeaderPrevHash (CC.blockHeader block)
         ) of
      (Left gh, hh) ->
         throwError $ CC.ChainValidationExpectedGenesisHash gh hh
      (Right expected, actual) ->
         unless (expected == actual) $
           throwError $ CC.ChainValidationInvalidHash expected actual

-- | Apply a boundary block
--
-- NOTE: The `cvsLastSlot` calculation must match the one in 'abobHdrSlotNo'.
validateBoundary :: MonadError CC.ChainValidationError m
                 => Gen.Config
                 -> CC.ABoundaryBlock ByteString
                 -> CC.ChainValidationState -> m CC.ChainValidationState
validateBoundary cfg blk cvs = do
    -- TODO: Unfortunately, 'updateChainBoundary' doesn't take a hash as an
    -- argument but recomputes it.
    cvs' <- CC.updateChainBoundary cvs blk
    -- TODO: For some reason 'updateChainBoundary' does not set the slot when
    -- applying an EBB, so we do it here. Could that cause problems??
    return cvs' {
        CC.cvsLastSlot = CC.boundaryBlockSlot epochSlots (CC.boundaryEpoch hdr)
      }
  where
    hdr        = CC.boundaryHeader blk
    epochSlots = Gen.configEpochSlots cfg

-- | Preview the delegation map at a slot assuming no new delegations are
-- | scheduled.
previewDelegationMap :: CC.SlotNumber
                     -> CC.ChainValidationState
                     -> Delegation.Map
previewDelegationMap slot cvs =
  let ds = D.Iface.activateDelegations slot $ CC.cvsDelegationState cvs
   in D.Iface.delegationMap ds

{-------------------------------------------------------------------------------
  Applying transactions
-------------------------------------------------------------------------------}

mkUtxoEnvironment :: Gen.Config
                  -> CC.ChainValidationState
                  -> Utxo.Environment
mkUtxoEnvironment cfg cvs = Utxo.Environment {
      Utxo.protocolMagic      = protocolMagic
    , Utxo.protocolParameters = U.Iface.adoptedProtocolParameters updateState
    , Utxo.utxoConfiguration  = Gen.configUTxOConfiguration cfg
    }
  where
    protocolMagic = reAnnotateMagic (Gen.configProtocolMagic cfg)
    updateState   = CC.cvsUpdateState cvs

mkDelegationEnvironment :: Gen.Config
                        -> CC.SlotNumber
                        -> D.Iface.Environment
mkDelegationEnvironment cfg currentSlot = D.Iface.Environment {
      D.Iface.protocolMagic     = getAProtocolMagicId protocolMagic
    , D.Iface.allowedDelegators = allowedDelegators cfg
    , D.Iface.k                 = k
      -- The @currentSlot@/@currentEpoch@ for checking a delegation certificate
      -- must be that of the block in which the delegation certificate is/will
      -- be included.
    , D.Iface.currentEpoch      = currentEpoch
    , D.Iface.currentSlot       = currentSlot
    }
  where
    k             = Gen.configK cfg
    protocolMagic = reAnnotateMagic (Gen.configProtocolMagic cfg)
    currentEpoch  = CC.slotNumberEpoch (Gen.configEpochSlots cfg) currentSlot

mkUpdateEnvironment :: Gen.Config
                    -> CC.ChainValidationState
                    -> U.Iface.Environment
mkUpdateEnvironment cfg cvs = U.Iface.Environment {
      U.Iface.protocolMagic = getAProtocolMagicId protocolMagic
    , U.Iface.k             = k
    , U.Iface.currentSlot   = currentSlot
    , U.Iface.numGenKeys    = numGenKeys
    , U.Iface.delegationMap = delegationMap
    }
  where
    k             = Gen.configK cfg
    protocolMagic = reAnnotateMagic (Gen.configProtocolMagic cfg)
    currentSlot   = CC.cvsLastSlot cvs
    numGenKeys    = toNumGenKeys $ Set.size (allowedDelegators cfg)
    delegationMap = getDelegationMap cvs

    -- TODO: This function comes straight from cardano-ledger, which however
    -- does not export it. We should either export it, or -- preferably -- when
    -- all of the functions in this module are moved to cardano-ledger, the
    -- function can just be used directly.
    toNumGenKeys :: Int -> Word8
    toNumGenKeys n
      | n > fromIntegral (maxBound :: Word8) = panic $
        "toNumGenKeys: Too many genesis keys"
      | otherwise = fromIntegral n

applyTxAux :: MonadError Utxo.UTxOValidationError m
           => CC.ValidationMode
           -> Gen.Config
           -> [Utxo.ATxAux ByteString]
           -> CC.ChainValidationState -> m CC.ChainValidationState
applyTxAux validationMode cfg txs cvs =
    flip runReaderT validationMode $
      (`setUTxO` cvs) <$>
        Utxo.updateUTxO utxoEnv utxo txs
  where
    utxoEnv = mkUtxoEnvironment cfg cvs
    utxo    = CC.cvsUtxo cvs

applyCertificate :: MonadError D.Sched.Error m
                 => Gen.Config
                 -> CC.SlotNumber
                 -> [Delegation.ACertificate ByteString]
                 -> CC.ChainValidationState -> m CC.ChainValidationState
applyCertificate cfg currentSlot certs cvs =
    (`setDelegationState` cvs) <$>
      D.Iface.updateDelegation dlgEnv dlgState certs
  where
    dlgEnv   = mkDelegationEnvironment cfg currentSlot
    dlgState = CC.cvsDelegationState cvs

applyUpdateProposal :: MonadError U.Iface.Error m
                    => Gen.Config
                    -> Update.AProposal ByteString
                    -> CC.ChainValidationState -> m CC.ChainValidationState
applyUpdateProposal cfg proposal cvs =
    (`setUpdateState` cvs) <$>
      U.Iface.registerProposal updateEnv updateState proposal
  where
    updateEnv   = mkUpdateEnvironment cfg cvs
    updateState = CC.cvsUpdateState cvs

applyUpdateVote :: MonadError U.Iface.Error m
                => Gen.Config
                -> Update.AVote ByteString
                -> CC.ChainValidationState -> m CC.ChainValidationState
applyUpdateVote cfg vote cvs =
    (`setUpdateState` cvs) <$>
      U.Iface.registerVote updateEnv updateState vote
  where
    updateEnv   = mkUpdateEnvironment cfg cvs
    updateState = CC.cvsUpdateState cvs

{-------------------------------------------------------------------------------
  Apply any kind of transactions
-------------------------------------------------------------------------------}

-- | Errors that arise from applying an arbitrary mempool payload
--
-- Although @cardano-legder@ defines 'MempoolPayload', it does not define a
-- corresponding error type. We could 'ChainValidationError', but it's too
-- large, which is problematic because we actually sent encoded versions of
-- these errors across the wire.
data ApplyMempoolPayloadErr =
    MempoolTxErr             Utxo.UTxOValidationError
  | MempoolDlgErr            D.Sched.Error
  | MempoolUpdateProposalErr U.Iface.Error
  | MempoolUpdateVoteErr     U.Iface.Error
  deriving (Eq, Show)

instance ToCBOR ApplyMempoolPayloadErr where
  toCBOR (MempoolTxErr err) =
    CBOR.encodeListLen 2 <> toCBOR (0 :: Word8) <> toCBOR err
  toCBOR (MempoolDlgErr err) =
    CBOR.encodeListLen 2 <> toCBOR (1 :: Word8) <> toCBOR err
  toCBOR (MempoolUpdateProposalErr err) =
    CBOR.encodeListLen 2 <> toCBOR (2 :: Word8) <> toCBOR err
  toCBOR (MempoolUpdateVoteErr err) =
    CBOR.encodeListLen 2 <> toCBOR (3 :: Word8) <> toCBOR err

instance FromCBOR ApplyMempoolPayloadErr where
  fromCBOR = do
    enforceSize "ApplyMempoolPayloadErr" 2
    CBOR.decodeWord8 >>= \case
      0   -> MempoolTxErr             <$> fromCBOR
      1   -> MempoolDlgErr            <$> fromCBOR
      2   -> MempoolUpdateProposalErr <$> fromCBOR
      3   -> MempoolUpdateVoteErr     <$> fromCBOR
      tag -> cborError $ DecoderErrorUnknownTag "ApplyMempoolPayloadErr" tag

applyMempoolPayload :: MonadError ApplyMempoolPayloadErr m
                    => CC.ValidationMode
                    -> Gen.Config
                    -> CC.SlotNumber
                    -> CC.AMempoolPayload ByteString
                    -> CC.ChainValidationState -> m CC.ChainValidationState
applyMempoolPayload validationMode cfg currentSlot payload =
    case payload of
      CC.MempoolTx tx ->
        (`wrapError` MempoolTxErr) .
          applyTxAux validationMode cfg [tx]
      CC.MempoolDlg cert ->
        (`wrapError` MempoolDlgErr) .
          applyCertificate cfg currentSlot [cert]
      CC.MempoolUpdateProposal proposal ->
        (`wrapError` MempoolUpdateProposalErr) .
          applyUpdateProposal cfg proposal
      CC.MempoolUpdateVote vote ->
        (`wrapError` MempoolUpdateVoteErr) .
          applyUpdateVote cfg vote

-- | The encoding of the mempool payload (without a 'AMempoolPayload' envelope)
mempoolPayloadRecoverBytes :: CC.AMempoolPayload ByteString -> ByteString
mempoolPayloadRecoverBytes = go
  where
    go :: CC.AMempoolPayload ByteString -> ByteString
    go (CC.MempoolTx             payload) = recoverBytes payload
    go (CC.MempoolDlg            payload) = recoverBytes payload
    go (CC.MempoolUpdateProposal payload) = recoverBytes payload
    go (CC.MempoolUpdateVote     payload) = recoverBytes payload

-- | Re-encode the mempool payload (without any envelope)
mempoolPayloadReencode :: CC.AMempoolPayload a -> ByteString
mempoolPayloadReencode = go
  where
    go :: forall a. CC.AMempoolPayload a -> ByteString
    go (CC.MempoolTx             payload) = reencode payload
    go (CC.MempoolDlg            payload) = reencode payload
    go (CC.MempoolUpdateProposal payload) = reencode payload
    go (CC.MempoolUpdateVote     payload) = reencode payload

    reencode :: (Functor f, ToCBOR (f ())) => f a -> ByteString
    reencode = CBOR.toStrictByteString . toCBOR . void

{-------------------------------------------------------------------------------
  Annotations
-------------------------------------------------------------------------------}

reAnnotateMagicId :: ProtocolMagicId -> Annotated ProtocolMagicId ByteString
reAnnotateMagicId pmi = reAnnotate $ Annotated pmi ()

reAnnotateMagic :: ProtocolMagic -> AProtocolMagic ByteString
reAnnotateMagic (AProtocolMagic a b) = AProtocolMagic (reAnnotate a) b

reAnnotateBlock :: CC.EpochSlots -> CC.ABlock () -> CC.ABlock ByteString
reAnnotateBlock epochSlots =
    reAnnotateUsing
      (CC.toCBORBlock    epochSlots)
      (CC.fromCBORABlock epochSlots)

reAnnotateBoundary :: ProtocolMagicId
                   -> CC.ABoundaryBlock ()
                   -> CC.ABoundaryBlock ByteString
reAnnotateBoundary pm =
    reAnnotateUsing
      (CC.toCBORABoundaryBlock pm)
      CC.fromCBORABoundaryBlock

-- | Generalization of 'reAnnotate'
reAnnotateUsing :: forall f a. Functor f
                => (f a -> Encoding)
                -> (forall s. Decoder s (f ByteSpan))
                -> f a -> f ByteString
reAnnotateUsing encoder decoder =
      (\bs -> splice bs $ CBOR.deserialiseFromBytes decoder bs)
    . CBOR.toLazyByteString
    . encoder
  where
    splice :: Show err
           => Lazy.ByteString
           -> Either err (Lazy.ByteString, f ByteSpan)
           -> f ByteString
    splice bs (Right (left, fSpan))
       | Lazy.null left = (Lazy.toStrict . slice bs) <$> fSpan
       | otherwise      = roundtripFailure "leftover bytes"
    splice _ (Left err) = roundtripFailure $ show err

    roundtripFailure :: forall x. T.Text -> x
    roundtripFailure err = panic $ T.intercalate ": " $ [
          "annotateBoundary"
        , "serialization roundtrip failure"
        , show err
        ]

{-------------------------------------------------------------------------------
  Header of a regular block or EBB

  The ledger layer defines 'ABlockOrBoundary', but no equivalent for headers.
-------------------------------------------------------------------------------}

-- | Check if a block matches its header
--
-- For EBBs, we're currently being more permissive here and not performing any
-- header-body validation but only checking whether an EBB header and EBB block
-- were provided. This seems to be fine as it won't cause any loss of consensus
-- with the old `cardano-sl` nodes.
abobMatchesBody :: CC.ABlockOrBoundaryHdr ByteString
                -> CC.ABlockOrBoundary ByteString
                -> Bool
abobMatchesBody hdr blk =
    case (hdr, blk) of
      (CC.ABOBBlockHdr hdr', CC.ABOBBlock blk') -> matchesBody hdr' blk'
      (CC.ABOBBoundaryHdr _, CC.ABOBBoundary _) -> True
      (CC.ABOBBlockHdr    _, CC.ABOBBoundary _) -> False
      (CC.ABOBBoundaryHdr _, CC.ABOBBlock    _) -> False
  where
    matchesBody :: CC.AHeader ByteString -> CC.ABlock ByteString -> Bool
    matchesBody hdr' blk' = isRight $
        CC.validateHeaderMatchesBody hdr' (CC.blockBody blk')
