{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- TODO rename the module / move defintions / whatever.
-- It's not about the network at all.

module Pos.Update.Network.Listeners
       ( handleProposal
       , handleVote
       ) where

import           Universum

import           Formatting (build, sformat, (%))

import           Pos.Core.Update (UpdateProposal (..), UpdateVote (..))
import           Pos.Update.Logic.Local (processProposal, processVote)
import           Pos.Update.Mode (UpdateMode)
import           Pos.Util.Trace (Trace)
import           Pos.Util.Trace.Unstructured (LogItem, logNotice, logWarning)

handleProposal
    :: forall ctx m .
       ( UpdateMode ctx m
       )
    => Trace m LogItem
    -> (UpdateProposal, [UpdateVote])
    -> m Bool
handleProposal logTrace (proposal, votes) = do
    res <- processProposal logTrace proposal
    logProp proposal res
    let processed = isRight res
    processed <$ when processed (mapM_ processVoteLog votes)
  where
    processVoteLog :: UpdateVote -> m ()
    processVoteLog vote = processVote logTrace vote >>= logVote vote
    logVote vote (Left cause) =
        logWarning logTrace $
            sformat ("Proposal is accepted but vote "%build%
                     " is rejected, the reason is: "%build)
                     vote cause
    logVote vote (Right _) = logVoteAccepted logTrace vote

    logProp prop (Left cause) =
        logWarning logTrace $
            sformat ("Processing of proposal "%build%
                     " failed, the reason is: "%build)
                prop cause
    -- Update proposals are accepted rarely (at least before Shelley),
    -- so it deserves 'Notice' severity.
    logProp prop (Right _) =
        logNotice logTrace (sformat ("Processing of proposal "%build%" is successful") prop)

----------------------------------------------------------------------------
-- UpdateVote
----------------------------------------------------------------------------

handleVote
    :: forall ctx m .
       ( UpdateMode ctx m
       )
    => Trace m LogItem
    -> UpdateVote
    -> m Bool
handleVote logTrace uv = do
    res <- processVote logTrace uv
    logProcess uv res
    pure $ isRight res
  where
    logProcess vote (Left cause) =
        logWarning logTrace $
            sformat ("Processing of vote "%build%" failed, the reason is: "%build)
                     vote cause
    logProcess vote (Right _) = logVoteAccepted logTrace vote

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- Update votes are accepted rarely (at least before Shelley), so
-- it deserves 'Notice' severity.
logVoteAccepted :: Trace m LogItem -> UpdateVote -> m ()
logVoteAccepted logTrace =
    logNotice logTrace . sformat ("Processing of vote "%build%"is successfull")
