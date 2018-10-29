{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

module Test.Cardano.Chain.Ssc.Bi
       ( tests
       ) where

import           Cardano.Prelude
import           Test.Cardano.Prelude

import           Hedgehog (Property)
import qualified Hedgehog as H

import           Cardano.Binary.Class (dropBytes)
import           Cardano.Chain.Ssc (SscPayload (..), SscProof (..),
                     dropCommitment, dropCommitmentsMap, dropInnerSharesMap,
                     dropOpeningsMap, dropSharesMap, dropSignedCommitment,
                     dropSscPayload, dropSscProof, dropVssCertificate,
                     dropVssCertificatesMap)

import           Test.Cardano.Binary.Helpers.GoldenRoundTrip
                     (deprecatedGoldenDecode, roundTripsBiShow)


--------------------------------------------------------------------------------
-- Commitment
--------------------------------------------------------------------------------

goldenDeprecatedCommitment :: Property
goldenDeprecatedCommitment =
  deprecatedGoldenDecode "Commitment" dropCommitment "test/golden/bi/ssc/Commitment"


--------------------------------------------------------------------------------
-- CommitmentsMap
--------------------------------------------------------------------------------

goldenDeprecatedCommitmentsMap :: Property
goldenDeprecatedCommitmentsMap = deprecatedGoldenDecode
  "CommitmentsMap"
  dropCommitmentsMap
  "test/golden/bi/ssc/CommitmentsMap"


--------------------------------------------------------------------------------
-- InnerSharesMap
--------------------------------------------------------------------------------

goldenDeprecatedInnerSharesMap :: Property
goldenDeprecatedInnerSharesMap = deprecatedGoldenDecode
  "InnerSharesMap"
  dropInnerSharesMap
  "test/golden/bi/ssc/InnerSharesMap"


--------------------------------------------------------------------------------
-- Opening
--------------------------------------------------------------------------------

goldenDeprecatedOpening :: Property
goldenDeprecatedOpening =
  deprecatedGoldenDecode "Opening" dropBytes "test/golden/bi/ssc/Opening"


--------------------------------------------------------------------------------
-- OpeningsMap
--------------------------------------------------------------------------------

goldenDeprecatedOpeningsMap :: Property
goldenDeprecatedOpeningsMap = deprecatedGoldenDecode
  "OpeningsMap"
  dropOpeningsMap
  "test/golden/bi/ssc/OpeningsMap"


--------------------------------------------------------------------------------
-- SignedCommitment
--------------------------------------------------------------------------------

goldenDeprecatedSignedCommitment :: Property
goldenDeprecatedSignedCommitment = deprecatedGoldenDecode
  "SignedCommitment"
  dropSignedCommitment
  "test/golden/bi/ssc/SignedCommitment"


--------------------------------------------------------------------------------
-- SharesMap
--------------------------------------------------------------------------------

goldenDeprecatedSharesMap :: Property
goldenDeprecatedSharesMap = deprecatedGoldenDecode
  "SharesMap"
  dropSharesMap
  "test/golden/bi/ssc/SharesMap"


--------------------------------------------------------------------------------
-- SscPayload
--------------------------------------------------------------------------------

goldenDeprecatedSscPayload_CommitmentsPayload :: Property
goldenDeprecatedSscPayload_CommitmentsPayload = deprecatedGoldenDecode
  "SscPayload_CommitmentsPayload"
  dropSscPayload
  "test/golden/bi/ssc/SscPayload_CommitmentsPayload"

goldenDeprecatedSscPayload_OpeningsPayload :: Property
goldenDeprecatedSscPayload_OpeningsPayload = deprecatedGoldenDecode
  "SscPayload_OpeningsPayload"
  dropSscPayload
  "test/golden/bi/ssc/SscPayload_OpeningsPayload"

goldenDeprecatedSscPayload_SharesPayload :: Property
goldenDeprecatedSscPayload_SharesPayload = deprecatedGoldenDecode
  "SscPayload_SharesPayload"
  dropSscPayload
  "test/golden/bi/ssc/SscPayload_SharesPayload"

goldenDeprecatedSscPayload_CertificatesPayload :: Property
goldenDeprecatedSscPayload_CertificatesPayload = deprecatedGoldenDecode
  "SscPayload_CertificatesPayload"
  dropSscPayload
  "test/golden/bi/ssc/SscPayload_CertificatesPayload"

roundTripSscPayload :: Property
roundTripSscPayload = eachOf 1 (pure SscPayload) roundTripsBiShow


--------------------------------------------------------------------------------
-- SscProof
--------------------------------------------------------------------------------

goldenDeprecatedSscProof_CommitmentsProof :: Property
goldenDeprecatedSscProof_CommitmentsProof = deprecatedGoldenDecode
  "SscProof_CommitmentsProof"
  dropSscProof
  "test/golden/bi/ssc/SscProof_CommitmentsProof"

goldenDeprecatedSscProof_OpeningsProof :: Property
goldenDeprecatedSscProof_OpeningsProof = deprecatedGoldenDecode
  "SscProof_OpeningsProof"
  dropSscProof
  "test/golden/bi/ssc/SscProof_OpeningsProof"

goldenDeprecatedSscProof_SharesProof :: Property
goldenDeprecatedSscProof_SharesProof = deprecatedGoldenDecode
  "SscProof_SharesProof"
  dropSscProof
  "test/golden/bi/ssc/SscProof_SharesProof"

goldenDeprecatedSscProof_CertificatesProof :: Property
goldenDeprecatedSscProof_CertificatesProof = deprecatedGoldenDecode
  "SscProof_CertificatesProof"
  dropSscProof
  "test/golden/bi/ssc/SscProof_CertificatesProof"

roundTripSscProof :: Property
roundTripSscProof = eachOf 1 (pure SscProof) roundTripsBiShow


--------------------------------------------------------------------------------
-- VssCertificate
--------------------------------------------------------------------------------

goldenDeprecatedVssCertificate :: Property
goldenDeprecatedVssCertificate = deprecatedGoldenDecode
  "VssCertificate"
  dropVssCertificate
  "test/golden/bi/ssc/VssCertificate"


--------------------------------------------------------------------------------
-- VssCertificatesHash
--------------------------------------------------------------------------------

goldenDeprecatedVssCertificatesHash :: Property
goldenDeprecatedVssCertificatesHash = deprecatedGoldenDecode
  "VssCertiificatesHash"
  dropBytes
  "test/golden/bi/ssc/VssCertificatesHash"


--------------------------------------------------------------------------------
-- VssCertificatesMap
--------------------------------------------------------------------------------

goldenDeprecatedVssCertificatesMap :: Property
goldenDeprecatedVssCertificatesMap = deprecatedGoldenDecode
  "VssCertificatesMap"
  dropVssCertificatesMap
  "test/golden/bi/ssc/VssCertificatesMap"


--------------------------------------------------------------------------------
-- Main test export
--------------------------------------------------------------------------------

tests :: IO Bool
tests = and <$> sequence
  [H.checkSequential $$discoverGolden, H.checkParallel $$discoverRoundTrip]
