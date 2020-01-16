{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
module Frontend.Store.V1 where

import Data.Aeson
import Data.Aeson.GADT.TH
import qualified Data.ByteString.Base16 as Base16
import Data.Constraint (Dict(Dict))
import Data.Constraint.Extras
import Data.Dependent.Map (DMap, DSum(..))
import qualified Data.Dependent.Map as DMap
import Data.Functor.Identity (Identity(Identity), runIdentity)
import qualified Data.IntMap as IntMap
import Data.Map (Map)
import Data.Maybe (fromJust)
import qualified Data.Map as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import Common.Wallet
import Common.Network (NetworkName, NodeRef)
import Common.OAuth (OAuthProvider(..))
import Common.GistStore (GistMeta)

import Frontend.Store.TH
import qualified Frontend.Store.V0 as V0
import qualified Frontend.Store.V0.Wallet as V0
import Frontend.Store.MigrationUtils

-- WARNING: Upstream deps. Check this when we bump pact and obelisk!
-- May be worth storing this in upstream independent datatypes.
import Pact.Types.ChainId (ChainId(ChainId))
import Pact.Types.ChainMeta (PublicMeta (..))
import Obelisk.OAuth.Common (AccessToken, OAuthState)

data StoreFrontend key a where
  StoreFrontend_Wallet_Keys :: StoreFrontend key (KeyStorage key)
  StoreFrontend_Wallet_Accounts :: StoreFrontend key AccountStorage

  StoreFrontend_Network_PublicMeta :: StoreFrontend key PublicMeta
  StoreFrontend_Network_Networks :: StoreFrontend key (Map NetworkName [NodeRef])
  StoreFrontend_Network_SelectedNetwork :: StoreFrontend key NetworkName

  StoreFrontend_OAuth_Tokens :: StoreFrontend key (Map OAuthProvider AccessToken)
  StoreFrontend_OAuth_State :: OAuthProvider -> StoreFrontend key OAuthState

  StoreFrontend_Gist_GistRequested :: StoreFrontend key (GistMeta, Text)

  StoreFrontend_ModuleExplorer_SessionFile :: StoreFrontend key Text

deriving instance Show (StoreFrontend key a)

-- This is a very simplistic first go at writing this function. Some more thought needs to
-- be put into how to best structure the datatypes and position these functions. But this works
-- pretty OK for now.
--
-- The gnarliest thing is that when you add V2, you'll probably have to make some copies of datatypes
-- and copy them into Store.V1 . And at that point you better well need to make sure that the migration
-- from V0 to V1 with these new types is exactly the same. Tests will catch this, but there is probably
-- a more Versioning aware way that we can structure common for this.
--
-- We don't have time for that kind of refactor in the time frame that we have
--
-- Also note that key can't change here, so its JSON instances need to be backwards compatible
-- forever.
upgradeFromV0 :: DMap (V0.StoreFrontend key) Identity -> DMap (StoreFrontend key) Identity
upgradeFromV0 v0 =
  DMap.fromList . catMaybes $
    [ copyKeyDSum V0.StoreNetwork_PublicMeta StoreFrontend_Network_PublicMeta v0
    , copyKeyDSum V0.StoreNetwork_Networks StoreFrontend_Network_Networks v0
    , copyKeyDSum V0.StoreNetwork_SelectedNetwork StoreFrontend_Network_SelectedNetwork v0
    -- Technically these are session only and shouldn't be here given the backup restore only works on
    -- local storage, but desktop ignores the session vs local distinction so migrating them probably
    -- does some good and certainly doesn't hurt.
    -- Also, this is currently being very lazy not leaning on the Universe instance of OAuthProvider
    , copyKeyDSum V0.StoreOAuth_Tokens StoreFrontend_OAuth_Tokens v0
    , copyKeyDSum (V0.StoreOAuth_State OAuthProvider_GitHub) (StoreFrontend_OAuth_State OAuthProvider_GitHub) v0

    , copyKeyDSum V0.StoreModuleExplorer_SessionFile StoreFrontend_ModuleExplorer_SessionFile v0
    , Just (StoreFrontend_Wallet_Keys :=> Identity newKeys)
    , Just (StoreFrontend_Wallet_Accounts :=> Identity newAccountStorage)
    ]
  where
    oldKeysList = maybe [] (IntMap.toList . runIdentity) (DMap.lookup V0.StoreWallet_Keys v0)
    (newKeysList, newAccountStorage) = foldMap splitOldKey oldKeysList
    newKeys = IntMap.fromList newKeysList

    -- It's unfortunate that we don't have the key around or access to crypto here to recreate the keys.
    -- TODO: Fiddle with this so we don't need to fake out the key
    -- I don't think we should run crypto derivation functions here. The web
    -- version would generate a new key! Perhaps we should punt this to be fixed
    -- upon key restoration by the user.
    -- TODO this needs attention if we can't hide anymore
    splitOldKey (keyIdx, V0.SomeAccount_Deleted) = ([(keyIdx, Key fakeKeyPair)], mempty)

    splitOldKey (keyIdx, V0.SomeAccount_Account a) =
      ([(keyIdx, Key (extractKey a))]
      , oldAccountToNewStorage a
      )

    oldAccountToNewStorage :: V0.Account key -> AccountStorage
    oldAccountToNewStorage a =
      let
        accountNameText = V0.unAccountName . V0._account_name $ a
        oldPubKey = V0._keyPair_publicKey . V0._account_key $ a
        pubKeyText = T.decodeUtf8 . Base16.encode . V0.unPublicKey $ oldPubKey
        chainIdText = V0.unChainId . V0._account_chainId $ a
        newChainId = ChainId chainIdText
        accountNotesText = V0.unAccountNotes . V0._account_notes $ a
        newAccountNotes = mkAccountNotes accountNotesText
        newUnfinishedXChain = V0._account_unfinishedCrossChainTransfer a

        accounts = if accountNameText /= pubKeyText
          then
            let newVanityAccount = VanityAccount newAccountNotes newUnfinishedXChain
                newAccountInfo = AccountInfo Nothing $ Map.singleton newChainId newVanityAccount
            in Map.singleton (AccountName accountNameText) newAccountInfo
          else mempty

      in AccountStorage $ Map.singleton (V0._account_network a) accounts

    upgradePublicKey = PublicKey . V0.unPublicKey

    --This is a bit unfortunate
    fakeKeyPair = KeyPair
      { _keyPair_publicKey = fromJust . textToKey . T.replicate 64 $ "0"
      , _keyPair_privateKey = Nothing
      }
    extractKey (V0.Account { V0._account_key = kp } ) = KeyPair
      -- This relies on the V0.Wallet.PublicKey FromJSON checking that it is Base16!
      { _keyPair_publicKey = upgradePublicKey $ V0._keyPair_publicKey kp
      , _keyPair_privateKey = V0._keyPair_privateKey kp
      }

-- The TH doesn't deal with the key type param well because the key in each constructor is actually a
-- different type variable to the one in the data decl.
--
-- src/Frontend/Store/V0.hs:69:1-29: error:
--    The exact Name ‘key_a2Kfr’ is not in scope
--      Probable cause: you used a unique Template Haskell name (NameU),
--      perhaps via newName, but did not bind it
--      If that's it, then -ddump-splices might be useful

instance ArgDict c (StoreFrontend key) where
  type ConstraintsFor (StoreFrontend key) c
    = ( c (KeyStorage key)
      , c AccountStorage
      , c PublicMeta
      , c (Map NetworkName [NodeRef])
      , c NetworkName
      , c (Map OAuthProvider AccessToken)
      , c OAuthState
      , c (GistMeta, Text)
      , c Text
      )
  argDict = \case
    StoreFrontend_Wallet_Keys {} -> Dict
    StoreFrontend_Wallet_Accounts {} -> Dict
    StoreFrontend_Network_PublicMeta {} -> Dict
    StoreFrontend_Network_Networks {} -> Dict
    StoreFrontend_Network_SelectedNetwork {} -> Dict
    StoreFrontend_OAuth_Tokens {} -> Dict
    StoreFrontend_OAuth_State {} -> Dict
    StoreFrontend_Gist_GistRequested {} -> Dict
    StoreFrontend_ModuleExplorer_SessionFile {} -> Dict

deriveStoreInstances ''StoreFrontend
deriveJSONGADT ''StoreFrontend
