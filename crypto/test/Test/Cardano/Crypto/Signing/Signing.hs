{-# LANGUAGE TemplateHaskell #-}

module Test.Cardano.Crypto.Signing.Signing (tests) where

import Cardano.Prelude

import Hedgehog
  (Gen, Property, assert, checkParallel, discover, forAll, property)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import Cardano.Binary (toCBOR)
import Cardano.Crypto.Signing (SignTag(..), sign, toPublic, verifySignature)

import qualified Test.Cardano.Crypto.Dummy as Dummy
import Test.Cardano.Crypto.Gen
  (genKeypair, genPublicKey, genSecretKey)


--------------------------------------------------------------------------------
-- Main Test Action
--------------------------------------------------------------------------------

tests :: IO Bool
tests = checkParallel $$discover


--------------------------------------------------------------------------------
-- Redeem Signature Properties
--------------------------------------------------------------------------------

-- | Signing and verification works
prop_sign :: Property
prop_sign = property $ do
  (pk, sk) <- forAll genKeypair
  a        <- forAll genData

  assert
    $ verifySignature toCBOR Dummy.dummyProtocolMagicId SignForTestingOnly pk a
    $ sign dummyProtocolMagicId SignForTestingOnly sk a

-- | Signing fails when the wrong 'PublicKey' is used
prop_signDifferentKey :: Property
prop_signDifferentKey = property $ do
  sk <- forAll genSecretKey
  pk <- forAll $ Gen.filter (/= toPublic sk) genPublicKey
  a  <- forAll genData

  assert
    . not
    $ verifySignature toCBOR Dummy.dummyProtocolMagicId SignForTestingOnly pk a
    $ sign dummyProtocolMagicId SignForTestingOnly sk a

-- | Signing fails when then wrong signature data is used
prop_signDifferentData :: Property
prop_signDifferentData = property $ do
  (pk, sk) <- forAll genKeypair
  a        <- forAll genData
  b        <- forAll $ Gen.filter (/= a) genData

  assert
    . not
    $ verifySignature toCBOR Dummy.dummyProtocolMagicId SignForTestingOnly pk b
    $ sign dummyProtocolMagicId SignForTestingOnly sk a

genData :: Gen [Int32]
genData = Gen.list (Range.constant 0 50) (Gen.int32 Range.constantBounded)
