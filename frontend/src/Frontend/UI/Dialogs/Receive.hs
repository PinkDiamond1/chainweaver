{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
-- | Dialog for displaying account information required for receiving transfers
-- Copyright   :  (C) 2018 Kadena
-- License     :  BSD-style (see the file LICENSE)
module Frontend.UI.Dialogs.Receive
  ( uiReceiveModal
  ) where

import Control.Applicative (liftA2, liftA3)
import Control.Lens ((^.), (<>~), _1, _2, _3, view)
import Control.Monad (void, (<=<))
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Maybe (MaybeT(..))
import Control.Error (hush, headMay)
import Data.Bifunctor (first)
import Data.Either (isLeft,rights)
import Data.Text (Text)
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Map as Map
import qualified Data.Aeson as Aeson
import qualified Data.HashMap.Lazy as HM

import Reflex
import Reflex.Dom

import Kadena.SigningApi (DappCap (..))
import Pact.Types.Capability (SigCapability (..))
import Pact.Types.Term (QualifiedName (..), KeySet (..), Name (..), BareName (..))
import Pact.Types.ChainMeta (PublicMeta (..), TTLSeconds)
import Pact.Types.PactValue (PactValue (..))
import Pact.Types.Exp (Literal (LString, LDecimal))
import Pact.Types.Runtime (GasLimit, GasPrice (..))
import Pact.Parse (ParsedDecimal (..))
import qualified Pact.Types.Scheme as PactScheme

import Language.Javascript.JSaddle.Types (MonadJSM)

import Frontend.Crypto.Class (PactKey (..), HasCrypto, cryptoGenPubKeyFromPrivate)
import Common.Wallet (parsePublicKey,toPactPublicKey)

import Frontend.Foundation
import Frontend.KadenaAddress
import Frontend.Network

import Frontend.UI.Dialogs.DeployConfirmation (CanSubmitTransaction, TransactionSubmitFeedback (..), submitTransactionWithFeedback)

import Frontend.UI.DeploymentSettings (uiMetaData, defaultGASCapability, transactionDisplayNetwork)

import Frontend.UI.Modal
import Frontend.UI.Widgets
import Frontend.UI.Widgets.Helpers (dialogSectionHeading)
import Frontend.UI.Widgets.AccountName (uiAccountNameInput)
import Frontend.Wallet

data NonBIP32TransferInfo = NonBIP32TransferInfo
  { _legacyTransferInfo_account :: AccountName
  , _legacyTransferInfo_amount :: GasPrice
  , _legacyTransferInfo_pactKey :: PactKey
  }

uiDisplayAddress
  :: ( MonadJSM (Performable m)
     , DomBuilder t m
     , PostBuild t m
     , PerformEvent t m
     )
  => Text
  -> m ()
uiDisplayAddress address = do
  dialogSectionHeading mempty "Kadena Address"
  divClass "group" $ do
    -- Kadena Address
    divClass "segment segment_type_tertiary labeled-input account-details__kadena-address-wrapper" $ do
      void $ uiInputElement $ def
        & initialAttributes <>~ ("disabled" =: "true" <> "class" =: "account-details__kadena-address labeled-input__input")
        & inputElementConfig_initialValue .~ address
      void $ copyButton (def
        & uiButtonCfg_class .~ constDyn "account-details__copy-btn button_type_confirm"
        & uiButtonCfg_title .~ constDyn (Just "Copy")
        ) $ pure address
      pure ()

uiReceiveFromLegacyAccount
  :: ( MonadWidget t m
     , HasWallet model key t
     , HasNetwork model t
     , HasCrypto key (Performable m)
     )
  => model
  -> m (Dynamic t (Maybe NonBIP32TransferInfo))
uiReceiveFromLegacyAccount model = do
  mAccountName <- uiAccountNameInput model (pure Nothing) Nothing

  onKeyPair <- divClass "account-details__private-key" $
    _inputElement_input <$> mkLabeledInput True "Private Key" uiInputElement def

  (deriveErr, okPair) <- fmap fanEither . performEvent $ deriveKeyPair <$> onKeyPair

  _ <- widgetHold blank $ leftmost
    [ text <$> deriveErr
    , blank <$ okPair
    ]

  keyPair <- holdDyn Nothing $ Just <$> okPair

  amount <- view _2 <$> mkLabeledInput True "Amount" uiGasPriceInputField def

  pure $ (liftA3 . liftA3) NonBIP32TransferInfo mAccountName amount keyPair
  where
    deriveKeyPair :: (HasCrypto key m, MonadJSM m) => Text -> m (Either Text PactKey)
    deriveKeyPair = fmap (first T.pack) . cryptoGenPubKeyFromPrivate PactScheme.ED25519

uiReceiveModal
  :: ( MonadWidget t m
     , Monoid mConf
     , HasNetwork model t
     , HasNetworkCfg mConf t
     , HasWallet model key t
     , Flattenable mConf t
     , HasCrypto key m
     , HasCrypto key (Performable m)
     )
  => model
  -> AccountName
  -> AccountCreated
  -> Maybe ChainId
  -> Event t ()
  -> m (mConf, Event t ())
uiReceiveModal model account accCreated mchain _onClose = do
  onClose <- modalHeader $ text "Receive"
  (conf, closes) <- fmap splitDynPure $ workflow $ uiReceiveModal0 model account accCreated mchain onClose
  mConf <- flatten =<< tagOnPostBuild conf
  let close = switch $ current closes
  pure (mConf, close)

uiReceiveModal0
  :: ( MonadWidget t m
     , Monoid mConf
     , HasNetwork model t
     , HasNetworkCfg mConf t
     , HasWallet model key t
     , HasCrypto key (Performable m)
     , HasCrypto key m
     )
  => model
  -> AccountName
  -> AccountCreated
  -> Maybe ChainId
  -> Event t ()
  -> Workflow t m (mConf, Event t ())
uiReceiveModal0 model account accCreated mchain onClose = Workflow $ do
  let

    netInfo = do
      nodes <- model ^. network_selectedNodes
      meta <- model ^. network_meta
      let networkId = hush . mkNetworkName . nodeVersion <=< headMay $ rights nodes
      pure $ (nodes, meta, ) <$> networkId

    displayText lbl v cls =
      let
        attrFn cfg = uiInputElement $ cfg
          & initialAttributes <>~ ("disabled" =: "true" <> "class" =: (" " <> cls))
      in
        mkLabeledInputView True lbl attrFn $ pure v

  (showingAddr, chain, (conf, ttl, gaslimit, transferInfo)) <- divClass "modal__main receive" $ do
    rec
      showingKadenaAddress <- toggle True $ onAddrClick <> onReceiClick

      dialogSectionHeading mempty "Destination"
      chain <- divClass "group" $ do
        -- Network
        transactionDisplayNetwork model
        -- Chain id
        case mchain of
          Nothing -> userChainIdSelect model
          Just cid -> (pure $ Just cid) <$ displayText "Chain ID" (_chainId cid) mempty

      (onAddrClick, ((), ())) <- controlledAccordionItem showingKadenaAddress mempty
        (accordionHeaderBtn "Option 1: Copy and share Kadena Address") $ do
        dyn_ $ ffor chain $ uiDisplayAddress . \case
          Nothing -> "Please select a chain"
          Just cid -> textKadenaAddress $ mkKadenaAddress accCreated cid account

      (onReceiClick, results) <- controlledAccordionItem (not <$> showingKadenaAddress) mempty
        (accordionHeaderBtn "Option 2: Transfer from non-Chainweaver Account") $ do
        dialogSectionHeading mempty "Sender Details"
        transferInfo0 <- divClass "group" $ uiReceiveFromLegacyAccount model
        dialogSectionHeading mempty "Transaction Settings"
        (conf0, ttl0, gaslimit0) <- divClass "group" $ uiMetaData model Nothing Nothing
        pure (conf0, ttl0, gaslimit0, transferInfo0)

    pure (showingKadenaAddress, chain, snd results)

  let needsSender = liftA2 (&&) (isNothing <$> transferInfo) (not <$> showingAddr)
      isDisabled = liftA2 (||) (isNothing <$> chain) needsSender

  doneNext <- modalFooter $ uiButtonDyn
    (def
     & uiButtonCfg_class <>~ "button_type_confirm"
     & uiButtonCfg_disabled .~ isDisabled
    )
    $ dynText (bool "Submit Transfer" "Close" <$> showingAddr)

  let
    done = gate (current showingAddr) doneNext
    deploy = gate (not <$> current showingAddr) doneNext

    submit = flip push deploy $ \() -> runMaybeT $ do
      c <- MaybeT $ sample $ current chain
      t <- lift $ sample $ current ttl
      g <- lift $ sample $ current gaslimit
      ni <- MaybeT $ sample $ current netInfo
      ti <- MaybeT $ sample $ current transferInfo
      pure $ receiveFromLegacySubmit onClose account accCreated c t g ni ti

  pure ( (conf, onClose <> done)
       , submit
       )

receiveFromLegacySubmit
  :: ( Monoid mConf
     , CanSubmitTransaction t m
     , HasCrypto key m
     )
  => Event t ()
  -> AccountName
  -> AccountCreated
  -> ChainId
  -> TTLSeconds
  -> GasLimit
  -> ([Either a NodeInfo], PublicMeta, NetworkName)
  -> NonBIP32TransferInfo
  -> Workflow t m (mConf, Event t ())
receiveFromLegacySubmit onClose account accCreated chain ttl gasLimit netInfo transferInfo = Workflow $ do
  let
    sender = _legacyTransferInfo_account transferInfo
    senderKey = _legacyTransferInfo_pactKey transferInfo
    senderPubKey = _pactKey_publicKey senderKey
    amount = _legacyTransferInfo_amount transferInfo

    unpackGasPrice (GasPrice (ParsedDecimal d)) = d

    code = T.unwords $
      [ "(coin." <> case accCreated of
          AccountCreated_No -> "transfer-create"
          AccountCreated_Yes -> "transfer"
      , tshow $ unAccountName $ sender
      , tshow $ unAccountName account
      , case accCreated of
          AccountCreated_No -> "(read-keyset 'key)"
          AccountCreated_Yes -> mempty
      , tshow amount
      , ")"
      ]

    transferSigCap = SigCapability
      { _scName = QualifiedName
        { _qnQual = "coin"
        , _qnName = "TRANSFER"
        , _qnInfo = def
        }
      , _scArgs =
        [ PLiteral $ LString $ unAccountName sender
        , PLiteral $ LString $ unAccountName account
        , PLiteral $ LDecimal (unpackGasPrice amount)
        ]
      }

    dat = case accCreated of
      AccountCreated_No
        | Right pk <- parsePublicKey (unAccountName account)
        -> HM.singleton "key" $ Aeson.toJSON $ KeySet (Set.singleton $ toPactPublicKey pk) (Name $ BareName "keys-all" def)
      _ -> mempty

    pkCaps = Map.singleton senderPubKey [_dappCap_cap defaultGASCapability, transferSigCap]

    pm = (netInfo ^. _2)
      { _pmChainId = chain
      , _pmSender = unAccountName sender
      , _pmGasLimit = gasLimit
      , _pmTTL = ttl
      }

  cmd <- buildCmdWithPactKey
    senderKey
    Nothing
    (netInfo ^. _3)
    pm
    [KeyPair (_pactKey_publicKey senderKey) Nothing]
    []
    code
    dat
    pkCaps

  txnSubFeedback <- elClass "div" "modal__main transaction_details" $
    submitTransactionWithFeedback cmd chain (netInfo ^. _1)

  let isDisabled = maybe True isLeft <$> _transactionSubmitFeedback_message txnSubFeedback

  done <- modalFooter $ uiButtonDyn
    (def & uiButtonCfg_class .~ "button_type_confirm" & uiButtonCfg_disabled .~ isDisabled)
    (text "Done")

  pure
    ( (mempty, done <> onClose)
    , never
    )