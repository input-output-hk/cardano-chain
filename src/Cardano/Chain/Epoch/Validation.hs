{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Chain.Epoch.Validation
  ( EpochError(..)
  , validateEpochFile
  , validateEpochFiles
  )
where

import Cardano.Prelude hiding (trace)

import Control.Monad.Trans.Resource (ResIO, runResourceT)
import Formatting (Format, build, sformat)
import Streaming (Of(..), Stream, hoist)
import qualified Streaming.Prelude as S

import qualified Cardano.BM.Configuration as Log
import Cardano.BM.Data.Severity as Log
import Cardano.BM.Observer.Monadic as BM
import Cardano.BM.Trace (Trace, appendName, logNotice)
import Cardano.Chain.Block
  ( ABlockOrBoundary(..)
  , ChainValidationError
  , ChainValidationState(..)
  , HeapSize
  , UTxOSize
  , blockSlot
  , calcUTxOSize
  , cvsLastSlot
  , updateChainBlockOrBoundary
  )
import Cardano.Chain.Epoch.File
  ( ParseError
  , mainnetEpochSlots
  , parseEpochFileWithBoundary
  , parseEpochFilesWithBoundary
  )
import qualified Cardano.Chain.Genesis as Genesis
import Cardano.Chain.Slotting
  (EpochIndex, SlotId, slotNumberEpoch, unflattenSlotId)
import Cardano.Chain.Txp (UTxO)


data EpochError
  = EpochParseError ParseError
  | EpochChainValidationError (Maybe SlotId) ChainValidationError
  | Initial
  deriving (Eq, Show)


-- | Check that a single epoch's `Block`s are valid by folding over them
validateEpochFile
  :: forall m
   . (MonadIO m, MonadError EpochError m)
  => Genesis.Config
  -> Trace m Text
  -> Log.Configuration
  -> ChainValidationState
  -> FilePath
  -> m ChainValidationState
validateEpochFile config trace logconf cvs fp = do
  subTrace <- appendName "epoch-validation" trace
  res      <- BM.bracketObserveX logconf subTrace Log.Info "benchmark" $
      liftIO $ runResourceT $ runExceptT $ foldChainValidationState
        config
        cvs
        stream
  either throwError (logResult subTrace) res
 where
  stream = parseEpochFileWithBoundary mainnetEpochSlots fp

  logResult :: Trace m Text -> ChainValidationState -> m ChainValidationState
  logResult trace' cvs' = cvs' <$ logNotice
    trace'
    (sformat
      epochValidationFormat
      (slotNumberEpoch (Genesis.configEpochSlots config) (cvsLastSlot cvs))
      utxoSize
      heapSize
    )
   where
    sizePair = calcUTxOSize (cvsUtxo cvs')
    utxoSize = snd sizePair
    heapSize = fst sizePair

  epochValidationFormat :: Format r (EpochIndex -> UTxOSize -> HeapSize UTxO -> r)
  epochValidationFormat =
    "Succesfully validated epoch " . build . "\n" .
    "Number of UTxO entries at the end of the epoch: " . build . "\n" .
    "UTxO heap size in words at the end of the epoch: " . build . "\n"


-- | Check that a list of epochs 'Block's are valid.
validateEpochFiles
  :: Genesis.Config
  -> ChainValidationState
  -> [FilePath]
  -> IO (Either EpochError ChainValidationState)
validateEpochFiles config cvs fps =
    runResourceT . runExceptT $ foldChainValidationState config cvs stream
  where stream = parseEpochFilesWithBoundary mainnetEpochSlots fps


-- | Fold chain validation over a 'Stream' of 'Block's
foldChainValidationState
  :: Genesis.Config
  -> ChainValidationState
  -> Stream (Of (ABlockOrBoundary ByteString)) (ExceptT ParseError ResIO) ()
  -> ExceptT EpochError ResIO ChainValidationState
foldChainValidationState config chainValState blocks = S.foldM_
  (\cvs block ->
    withExceptT (EpochChainValidationError (blockOrBoundarySlot block))
      $ updateChainBlockOrBoundary config cvs block
  )
  (pure chainValState)
  pure $ hoist (withExceptT EpochParseError) blocks
 where
  blockOrBoundarySlot :: ABlockOrBoundary a -> Maybe SlotId
  blockOrBoundarySlot = \case
    ABOBBoundary _     -> Nothing
    ABOBBlock    block -> Just . unflattenSlotId mainnetEpochSlots $ blockSlot block
