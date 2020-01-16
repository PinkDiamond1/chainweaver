{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TypeApplications #-}
-- | Dialog for viewing the details of a key.
-- Copyright   :  (C) 2018 Kadena
-- License     :  BSD-style (see the file LICENSE)
module Frontend.UI.Dialogs.KeyDetails
  ( uiKeyDetails
  ) where

------------------------------------------------------------------------------
import           Control.Error
import           Control.Lens
import           Data.Functor (void)
import qualified Data.Text.Encoding as T
import qualified Data.IntMap as IntMap
import           Pact.Types.Util             (decodeBase64UrlUnpadded)
------------------------------------------------------------------------------
import           Reflex
import           Reflex.Dom hiding (Key)
------------------------------------------------------------------------------
import           Frontend.Crypto.Class
import           Frontend.Foundation
import           Frontend.UI.Modal
import           Frontend.UI.Widgets
import           Frontend.Wallet
------------------------------------------------------------------------------

uiKeyDetails
  :: ( Monoid mConf
     , HasCrypto key m
     , MonadWidget t m
     )
  => IntMap.Key
  -> Key key
  -> Event t ()
  -> m (mConf, Event t ())
uiKeyDetails _keyIndex key _onCloseExternal = mdo
  onClose <- modalHeader $ text "Key Details"
  let displayText lbl v cls =
        let
          attrFn cfg = uiInputElement $ cfg
            & initialAttributes <>~ ("disabled" =: "true" <> "class" =: (" " <> cls))
        in
          mkLabeledInputView False lbl attrFn $ pure v

      withSecretKey f = case _keyPair_privateKey . _key_pair $ key of
        Nothing -> text "Public key does not have a matching secret key - use a keypair generated by Chainweaver instead"
        Just x -> f x

  divClass "modal__main key-details" $ do
    divClass "group" $ do
      -- Public key
      _ <- displayText "Public Key" (keyToText $ _keyPair_publicKey $ _key_pair key) "key-details__pubkey"

      void $ accordionItemWithClick False mempty (accordionHeaderBtn "Advanced") $ withSecretKey $ \pk -> do
        txt <- fmap value $ mkLabeledClsInput False "Data to sign (Base64Url Unpadded)" $ \cls -> uiTextAreaElement $ def
          & initialAttributes .~ "class" =: renderClass cls

        ((), sigEv) <- runWithReplace blank $ ffor (fmapMaybe (hush . decodeBase64UrlUnpadded . T.encodeUtf8) $ updated txt) $ \case
          "" -> pure Nothing
          b -> Just . keyToText <$> cryptoSign b pk

        sig <- maybeDyn =<< holdDyn Nothing sigEv


        void $ mkLabeledClsInput False "Signature" $ \cls -> uiTextAreaElement $ def
          & initialAttributes .~ mconcat
            [ "class" =: renderClass cls
            , "disabled" =: ""
            , "placeholder" =: "Enter some text in the above field"
            ]
          & textAreaElementConfig_setValue .~ ffor sigEv fold

        dyn_ $ ffor sig $ \case
          Nothing -> blank
          Just sig' -> uiDetailsCopyButton $ current sig'

  modalFooter $ do
    onDone <- confirmButton def "Done"

    let done = leftmost [onClose, onDone]

    pure (mempty, done)
