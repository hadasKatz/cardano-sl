{-# LANGUAGE RankNTypes #-}
module Cardano.Wallet.API.V0.Handlers where

import qualified Cardano.Wallet.API.V0 as V0
import           Ntp.Client (NtpStatus)
import           Pos.Crypto (ProtocolMagic)
import           Pos.Infra.Diffusion.Types (Diffusion (sendTx))
import           Pos.Txp.Configuration (TxpConfiguration)
import           Pos.Util.CompileInfo (HasCompileInfo)
import           Pos.Wallet.Web.Mode (MonadFullWalletWebMode)
import qualified Pos.Wallet.Web.Server.Handlers as V0
import           Servant
import           Universum


-- | "Hook" the old API so that it can co-exist alongside
-- other versions. This has to be interpreted as the following:
-- "As long as you can give me a function which transforms every
-- monad @m@ which implements a `MonadFullWalletWebMode` into
-- a Servant's @Handler@, I can give you back a "plain old" Server.
handlers :: ( MonadFullWalletWebMode ctx m, HasCompileInfo )
         => (forall a. m a -> Handler a)
         -> ProtocolMagic
         -> TxpConfiguration
         -> Diffusion m
         -> TVar NtpStatus
         -> Server V0.API
handlers naturalTransformation pm txpConfig diffusion ntpStatus = hoistServer
    (Proxy @V0.API)
    naturalTransformation
    (V0.servantHandlers pm txpConfig ntpStatus (sendTx diffusion))
