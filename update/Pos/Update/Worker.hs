-- | Update System related workers.

module Pos.Update.Worker
       ( usWorkers

       , updateTriggerWorker
       ) where

import           Universum

import           Formatting (build, sformat, (%))
import           Data.Functor.Contravariant (contramap)
import           Serokell.Util.Text (listJsonIndent)

import           Pos.Core (SoftwareVersion (..))
import           Pos.Core.Update (UpdateProposal (..))
import           Pos.Diffusion.Types (Diffusion)
import           Pos.Recovery.Info (recoveryCommGuard)
import           Pos.Shutdown (triggerShutdown)
import           Pos.Slotting.Util (ActionTerminationPolicy (..), OnNewSlotParams (..),
                                    defaultOnNewSlotParams, onNewSlotNoLogging)
import           Pos.Update.Configuration (curSoftwareVersion)
import           Pos.Update.Context (UpdateContext (..))
import           Pos.Update.DB (getConfirmedProposals)
import           Pos.Update.Download (downloadUpdate)
import           Pos.Update.Logic.Local (processNewSlot)
import           Pos.Update.Mode (UpdateMode)
import           Pos.Update.Poll.Types (ConfirmedProposalState (..))
import           Pos.Util.Util (lensOf)
import           Pos.Util.Trace (Trace)
import           Pos.Util.Trace.Unstructured (LogItem, logDebug, logInfo,
                                              publicPrivateLogItem)
import           Pos.Util.Trace.Wlog (LogNamed, named)

-- | Update System related workers.
usWorkers
    :: forall ctx m.
       ( UpdateMode ctx m
       )
    => Trace m (LogNamed LogItem)
    -> [Diffusion m -> m ()]
usWorkers namedLogTrace = [processNewSlotWorker, checkForUpdateWorker]
  where
    -- These are two separate workers. We want them to run in parallel
    -- and not affect each other.
    processNewSlotParams = defaultOnNewSlotParams
        { onspTerminationPolicy =
              NewSlotTerminationPolicy "Update.processNewSlot"
        }
    processNewSlotWorker = \_ ->
        onNewSlotNoLogging processNewSlotParams $ \s ->
            recoveryCommGuard logTrace "processNewSlot in US" $ do
                logDebug logTrace "Updating slot for US..."
                processNewSlot logTrace s
    checkForUpdateWorker = \_ ->
        onNewSlotNoLogging defaultOnNewSlotParams $ \_ ->
            recoveryCommGuard logTrace "checkForUpdate" (checkForUpdate @ctx @m logTrace)
    logTrace = named namedLogTrace

checkForUpdate ::
       forall ctx m. UpdateMode ctx m
    => Trace m LogItem
    -> m ()
checkForUpdate logTrace = do
    logDebug logTrace "Checking for update..."
    confirmedProposals <-
        getConfirmedProposals (Just $ svNumber curSoftwareVersion)
    case nonEmpty confirmedProposals of
        Nothing ->
            logDebug logTrace
                "There are no new confirmed update proposals for our application"
        Just confirmedProposalsNE -> processProposals confirmedProposalsNE
  where
    processProposals :: NonEmpty ConfirmedProposalState -> m ()
    processProposals confirmedProposals = do
        let cpsToNumericVersion =
                svNumber . upSoftwareVersion . cpsUpdateProposal
        let newestCPS =
                maximumBy (comparing cpsToNumericVersion) confirmedProposals
        logInfo logTrace $
            sformat
                ("There are new confirmed update proposals for our application: "
                 %listJsonIndent 2%
                 "\n The newest one is: "%build%" and we want to download it")
                (cpsUpdateProposal <$> confirmedProposals)
                (cpsUpdateProposal newestCPS)
        downloadUpdate logTrace newestCPS

-- | This worker is just waiting until we download an update for our
-- application. When an update is downloaded, it shuts the system
-- down. It should be used in there is no high-level code which shuts
-- down the system (e. g. in regular node w/o wallet or in explorer).
updateTriggerWorker
    :: UpdateMode ctx m
    => Trace m LogItem
    -> Diffusion m
    -> m ()
updateTriggerWorker logTrace = \_ -> do
    logInfo logTrace "Update trigger worker is locked"
    void $ takeMVar . ucDownloadedUpdate =<< view (lensOf @UpdateContext)
    triggerShutdown (contramap publicPrivateLogItem logTrace)
