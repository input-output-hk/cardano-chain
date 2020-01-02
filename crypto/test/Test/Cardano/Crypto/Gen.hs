module Test.Cardano.Crypto.Gen
  (
  -- * Protocol Magic Generator
    genProtocolMagic
  , genProtocolMagicId
  , genRequiresNetworkMagic

  -- * Sign Tag Generator
  , genSignTag

  -- * Key Generators
  , genKeypair
  , genVerificationKey
  , genSigningKey

  -- * Redeem Key Generators
  , genRedeemKeypair
  , genRedeemVerificationKey
  , genCompactRedeemVerificationKey
  , genRedeemSigningKey

  -- * Signature Generators
  , genSignature
  , genSignatureEncoded
  , genRedeemSignature

  -- * Hash Generators
  , genAbstractHash

  -- * SafeSigner Generators
  , genSafeSigner

  -- * PassPhrase Generators
  , genPassPhrase

  -- * Helper Generators
  , genHashRaw
  , genTextHash
  , feedPM
  )
where

import Cardano.Prelude
import Test.Cardano.Prelude

import qualified Data.ByteArray as ByteArray
import Data.Coerce (coerce)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import Cardano.Binary (Raw(..), ToCBOR)
import Cardano.Crypto (PassPhrase)
import Cardano.Crypto.Hashing
  (AbstractHash(..), Hash, HashAlgorithm, abstractHash, hash)
import Cardano.Crypto.ProtocolMagic
  ( ProtocolMagic(..)
  , ProtocolMagicId(..)
  , RequiresNetworkMagic(..)
  )
import Cardano.Crypto.Signing
  ( VerificationKey
  , SafeSigner(..)
  , SigningKey
  , SignTag(..)
  , Signature
  , deterministicKeyGen
  , emptyPassphrase
  , sign
  , signRaw
  )
import Cardano.Crypto.Signing.Redeem
  ( CompactRedeemVerificationKey
  , RedeemVerificationKey
  , RedeemSigningKey
  , RedeemSignature
  , redeemDeterministicKeyGen
  , redeemSign
  , toCompactRedeemVerificationKey
  )
import Test.Cardano.Crypto.Orphans ()


--------------------------------------------------------------------------------
-- Protocol Magic Generator
--------------------------------------------------------------------------------

genProtocolMagic :: Gen ProtocolMagic
genProtocolMagic =
  ProtocolMagic
    <$> genProtocolMagicId
    <*> genRequiresNetworkMagic

-- | Whilst 'ProtocolMagicId' is represented as a 'Word32' in cardano-ledger,
-- in @cardano-sl@ it was an 'Int32'. In order to tolerate this, and since we
-- don't care about testing compatibility with negative values, we only
-- generate values between @0@ and @(maxBound :: Int32) - 1@, inclusive.
genProtocolMagicId :: Gen ProtocolMagicId
genProtocolMagicId = ProtocolMagicId
  <$> Gen.word32 (Range.constant 0 $ fromIntegral (maxBound :: Int32) - 1)

genRequiresNetworkMagic :: Gen RequiresNetworkMagic
genRequiresNetworkMagic = Gen.element [RequiresNoMagic, RequiresMagic]

--------------------------------------------------------------------------------
-- Sign Tag Generator
--------------------------------------------------------------------------------

genSignTag :: Gen SignTag
genSignTag = Gen.choice
  [ pure SignForTestingOnly
  , pure SignTx
  , pure SignRedeemTx
  , pure SignVssCert
  , pure SignUSProposal
  , pure SignCommitment
  , pure SignUSVote
  , SignBlock <$> genVerificationKey
  , pure SignCertificate
  ]


--------------------------------------------------------------------------------
-- Key Generators
--------------------------------------------------------------------------------

genKeypair :: Gen (VerificationKey, SigningKey)
genKeypair = deterministicKeyGen <$> gen32Bytes

genVerificationKey :: Gen VerificationKey
genVerificationKey = fst <$> genKeypair

genSigningKey :: Gen SigningKey
genSigningKey = snd <$> genKeypair


--------------------------------------------------------------------------------
-- Redeem Key Generators
--------------------------------------------------------------------------------

genRedeemKeypair :: Gen (RedeemVerificationKey, RedeemSigningKey)
genRedeemKeypair = Gen.just $ redeemDeterministicKeyGen <$> gen32Bytes

genRedeemVerificationKey :: Gen RedeemVerificationKey
genRedeemVerificationKey = fst <$> genRedeemKeypair

genCompactRedeemVerificationKey :: Gen CompactRedeemVerificationKey
genCompactRedeemVerificationKey =
  toCompactRedeemVerificationKey <$> genRedeemVerificationKey

genRedeemSigningKey :: Gen RedeemSigningKey
genRedeemSigningKey = snd <$> genRedeemKeypair


--------------------------------------------------------------------------------
-- Signature Generators
--------------------------------------------------------------------------------

genSignature :: ToCBOR a => ProtocolMagicId -> Gen a -> Gen (Signature a)
genSignature pm genA = sign pm <$> genSignTag <*> genSigningKey <*> genA

genSignatureEncoded :: Gen ByteString -> Gen (Signature a)
genSignatureEncoded genB =
  coerce . signRaw <$> genProtocolMagicId <*> (Just <$> genSignTag) <*> genSigningKey <*> genB

genRedeemSignature
  :: ToCBOR a => ProtocolMagicId -> Gen a -> Gen (RedeemSignature a)
genRedeemSignature pm genA = redeemSign pm <$> gst <*> grsk <*> genA
 where
  gst  = genSignTag
  grsk = genRedeemSigningKey


--------------------------------------------------------------------------------
-- Hash Generators
--------------------------------------------------------------------------------

genAbstractHash
  :: (ToCBOR a, HashAlgorithm algo) => Gen a -> Gen (AbstractHash algo a)
genAbstractHash genA = abstractHash <$> genA


--------------------------------------------------------------------------------
-- PassPhrase Generators
--------------------------------------------------------------------------------

genPassPhrase :: Gen PassPhrase
genPassPhrase = ByteArray.pack <$> genWord8List
 where
  genWord8List :: Gen [Word8]
  genWord8List =
    Gen.list (Range.singleton 32) (Gen.word8 Range.constantBounded)


--------------------------------------------------------------------------------
-- SafeSigner Generators
--------------------------------------------------------------------------------

genSafeSigner :: Gen SafeSigner
genSafeSigner = SafeSigner <$> genSigningKey <*> pure emptyPassphrase


--------------------------------------------------------------------------------
-- Helper Generators
--------------------------------------------------------------------------------

genHashRaw :: Gen (Hash Raw)
genHashRaw = genAbstractHash $ Raw <$> gen32Bytes

genTextHash :: Gen (Hash Text)
genTextHash = hash <$> Gen.text (Range.linear 0 10) Gen.alphaNum

feedPM :: (ProtocolMagicId -> Gen a) -> Gen a
feedPM genA = genA =<< genProtocolMagicId
