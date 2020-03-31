{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.Wallet.Primitive.AddressDerivationSpec
    ( spec

    -- * Generators
    , genAddress
    , genLegacyAddress
    ) where

import Prelude

import Cardano.Crypto.Wallet
    ( XPub, unXPrv, xpub )
import Cardano.Wallet.Gen
    ( genMnemonic )
import Cardano.Wallet.Primitive.AddressDerivation
    ( Depth (..)
    , DerivationType (..)
    , ErrWrongPassphrase (..)
    , FromMnemonic (..)
    , FromMnemonicError (..)
    , Index
    , NetworkDiscriminant (..)
    , Passphrase (..)
    , PassphraseMaxLength (..)
    , PassphraseMinLength (..)
    , PersistPrivateKey (..)
    , PersistPublicKey (..)
    , SomeMnemonic (..)
    , WalletKey (..)
    , XPrv
    , checkPassphrase
    , encryptPassphrase
    , getIndex
    , hex
    , preparePassphrase
    , unXPrvStripPub
    , unXPrvStripPubCheckRoundtrip
    , xPrvFromStrippedPubXPrv
    , xPrvFromStrippedPubXPrvCheckRoundtrip
    )
import Cardano.Wallet.Primitive.AddressDerivation.Byron
    ( ByronKey (..) )
import Cardano.Wallet.Primitive.AddressDerivation.Icarus
    ( IcarusKey (..) )
import Cardano.Wallet.Primitive.AddressDerivation.Shelley
    ( KnownNetwork (..), ShelleyKey (..) )
import Cardano.Wallet.Primitive.Types
    ( Address (..), Hash (..), PassphraseScheme (..), ProtocolMagic (..) )
import Cardano.Wallet.Unsafe
    ( unsafeFromHex )
import Control.Arrow
    ( left )
import Control.Monad
    ( replicateM, (>=>) )
import Control.Monad.IO.Class
    ( liftIO )
import Data.Either
    ( isLeft, isRight )
import Data.Function
    ( (&) )
import Data.Proxy
    ( Proxy (..) )
import Test.Hspec
    ( Spec, describe, it, shouldBe, shouldSatisfy )
import Test.QuickCheck
    ( Arbitrary (..)
    , Gen
    , InfiniteList (..)
    , NonNegative (..)
    , Property
    , arbitraryBoundedEnum
    , arbitraryPrintableChar
    , choose
    , classify
    , counterexample
    , expectFailure
    , label
    , oneof
    , property
    , vector
    , (.&&.)
    , (===)
    , (==>)
    )
import Test.QuickCheck.Arbitrary.Generic
    ( genericArbitrary )
import Test.QuickCheck.Monadic
    ( monadicIO )
import Test.Text.Roundtrip
    ( textRoundtrip )

import qualified Cardano.Byron.Codec.Cbor as CBOR
import qualified Cardano.Wallet.Primitive.AddressDerivation.Byron as Rnd
import qualified Cardano.Wallet.Primitive.AddressDerivation.Icarus as Ica
import qualified Cardano.Wallet.Primitive.AddressDerivation.Shelley as Seq
import qualified Codec.CBOR.Encoding as CBOR
import qualified Codec.CBOR.Write as CBOR
import qualified Crypto.Scrypt as Scrypt
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

spec :: Spec
spec = describe "PATATE" $ do
    describe "Bounded / Enum relationship" $ do
        it "The calls Index.succ maxBound should result in a runtime err (hard)"
            prop_succMaxBoundHardIx
        it "The calls Index.pred minBound should result in a runtime err (hard)"
            prop_predMinBoundHardIx
        it "The calls Index.succ maxBound should result in a runtime err (soft)"
            prop_succMaxBoundSoftIx
        it "The calls Index.pred minBound should result in a runtime err (soft)"
            prop_predMinBoundSoftIx

    describe "Text Roundtrip" $ do
        textRoundtrip $ Proxy @(Passphrase "raw")

    describe "Enum Roundtrip" $ do
        it "Index @'Hardened _" (property prop_roundtripEnumIndexHard)
        it "Index @'Soft _" (property prop_roundtripEnumIndexSoft)

    describe "Passphrases" $ do
        it "checkPassphrase p h(p) == Right ()" $
            property prop_passphraseRoundtrip
        it "p /= p' => checkPassphrase p' h(p) == Left ErrWrongPassphrase" $
            property prop_passphraseRoundtripFail
        it "checkPassphrase fails when hash is malformed" $
            property prop_passphraseHashMalformed
        it "checkPassphrase p h(p) == Right () for Scrypt passwords" $
            property prop_passphraseFromScryptRoundtrip
        it "p /= p' => checkPassphrase p' h(p) == Left ErrWrongPassphrase for Scrypt passwords" $
            property prop_passphraseFromScryptRoundtripFail

    describe "FromMnemonic" $ do
        let noInDictErr =
                "Found an unknown word not present in the pre-defined dictionary. \
                \The full dictionary is available here: https://github.com/input\
                \-output-hk/cardano-wallet/tree/master/specifications/mnemonic/english.txt"

        it "early error reported first (Invalid Entropy)" $ do
            let res = fromMnemonic @'[15,18,21]
                        [ "glimpse", "paper", "toward", "fine", "alert"
                        , "baby", "pyramid", "alone", "shaft", "force"
                        , "circle", "fancy", "squeeze", "cannon", "toilet"
                        ]
            res `shouldBe` Left (FromMnemonicError "Invalid entropy checksum: \
                \please double-check the last word of your mnemonic sentence.")

        it "early error reported first (Non-English Word)" $ do
            let res = fromMnemonic @'[15,18,21]
                        [ "baguette", "paper", "toward", "fine", "alert"
                        , "baby", "pyramid", "alone", "shaft", "force"
                        , "circle", "fancy", "squeeze", "cannon", "toilet"
                        ]
            res `shouldBe` Left (FromMnemonicError noInDictErr)

        it "early error reported first (Wrong number of words - 1)" $ do
            let res = fromMnemonic @'[15,18,21]
                        ["mom", "unveil", "slim", "abandon"
                        , "nut", "cash", "laugh", "impact"
                        , "system", "split", "depth", "sun"
                        ]
            res `shouldBe` Left (FromMnemonicError "Invalid number of words: \
                \15, 18 or 21 words are expected.")

        it "early error reported first (Wrong number of words - 2)" $ do
            let res = fromMnemonic @'[15]
                        ["mom", "unveil", "slim", "abandon"
                        , "nut", "cash", "laugh", "impact"
                        , "system", "split", "depth", "sun"
                        ]
            res `shouldBe` Left (FromMnemonicError "Invalid number of words: \
                \15 words are expected.")

        it "early error reported first (Error not in first constructor)" $ do
            let res = fromMnemonic @'[15,18,21,24]
                        ["盗", "精", "序", "郎", "赋", "姿", "委", "善", "酵"
                        ,"祥", "赛", "矩", "蜡", "注", "韦", "效", "义", "冻"
                        ]
            res `shouldBe` Left (FromMnemonicError noInDictErr)

        it "early error reported first (Error not in first constructor)" $ do
            let res = fromMnemonic @'[12,15,18]
                        ["盗", "精", "序", "郎", "赋", "姿", "委", "善", "酵"
                        ,"祥", "赛", "矩", "蜡", "注", "韦", "效", "义", "冻"
                        ]
            res `shouldBe` Left (FromMnemonicError noInDictErr)

        it "successfully parse 15 words in [15,18,21]" $ do
            let res = fromMnemonic @'[15,18,21]
                        ["cushion", "anxiety", "oval", "village", "choose"
                        , "shoot", "over", "behave", "category", "cruise"
                        , "track", "either", "maid", "organ", "sock"
                        ]
            res `shouldSatisfy` isRight

        it "successfully parse 15 words in [12,15,18]" $ do
            let res = fromMnemonic @'[12,15,18]
                        ["cushion", "anxiety", "oval", "village", "choose"
                        , "shoot", "over", "behave", "category", "cruise"
                        , "track", "either", "maid", "organ", "sock"
                        ]
            res `shouldSatisfy` isRight

        it "successfully parse 15 words in [9,12,15]" $ do
            let res = fromMnemonic @'[9,12,15]
                        ["cushion", "anxiety", "oval", "village", "choose"
                        , "shoot", "over", "behave", "category", "cruise"
                        , "track", "either", "maid", "organ", "sock"
                        ]
            res `shouldSatisfy` isRight

    describe "Keys storing and retrieving roundtrips" $ do
        it "XPrv ShelleyKey"
            (property $ prop_roundtripXPrv @ShelleyKey)
        it "XPrv IcarusKey"
            (property $ prop_roundtripXPrv @IcarusKey)
        it "XPrv ByronKey"
            (property $ prop_roundtripXPrv @ByronKey)
        it "XPub ShelleyKey"
            (property $ prop_roundtripXPub @ShelleyKey)
        it "XPub IcarusKey"
            (property $ prop_roundtripXPub @IcarusKey)

    describe "unXPrvStripPub & xPrvFromStrippedPubXPrv" $ do
        it "xPrvFromStrippedPubXPrv and unXPrvStripPub"
              (property prop_strippedPubXPrvRoundtrip1)
        it "xPrvFromStrippedPubXPrv and unXPrvStripPubCheckRoundtrip"
              (property prop_strippedPubXPrvRoundtrip2)
        it "xPrvFromStrippedPubXPrvCheckRoundtrip and unXPrvStripPub"
              (property prop_strippedPubXPrvRoundtrip3)
        it "xPrvFromStrippedPubXPrvCheckRoundtrip and unXPrvStripPubCheckRoundtrip"
              (property prop_strippedPubXPrvRoundtrip4)
        it "(xPrvFromStrippedPubXPrv bs) fails if (BS.length bs) /= 96"
            (property prop_xPrvFromStrippedPubXPrvLengthRequirement)

    describe "golden test legacy passphrase encryption" $ do
        it "compare new implementation with cardano-sl - short password" $ do
            let pwd  = Passphrase @"raw" $ BA.convert $ T.encodeUtf8 "patate"
            let hash = Hash $ unsafeFromHex
                    "31347c387c317c574342652b796362417576356c2b4258676a344a314c\
                    \6343675375414c2f5653393661364e576a2b7550766655513d3d7c2f37\
                    \6738486c59723174734e394f6e4e753253302b6a65515a6b5437316b45\
                    \414941366a515867386539493d"
            checkPassphrase EncryptWithScrypt pwd hash `shouldBe` Right ()
        it "compare new implementation with cardano-sl - normal password" $ do
            let pwd  = Passphrase @"raw" $ BA.convert $ T.encodeUtf8 "Secure Passphrase"
            let hash = Hash $ unsafeFromHex
                    "31347c387c317c714968506842665966555a336f5156434c384449744b\
                    \677642417a6c584d62314d6d4267695433776a556f3d7c53672b436e30\
                    \4232766b4475682f704265335569694577633364385845756f55737661\
                    \42514e62464443353569474f4135736e453144326743346f47564c472b\
                    \524331385958326c6863552f36687a38432f496172773d3d"
            checkPassphrase EncryptWithScrypt pwd hash `shouldBe` Right ()
        it "compare new implementation with cardano-sl - empty password" $ do
            let pwd  = Passphrase @"raw" $ BA.convert $ T.encodeUtf8 ""
            let hash = Hash $ unsafeFromHex
                    "31347c387c317c5743424875746242496c6a66734d764934314a30727a7\
                    \9663076657375724954796376766a793150554e377452673d3d7c54753\
                    \434596d6e547957546c5759674a3164494f7974474a7842632b432f786\
                    \2507657382b5135356a38303d"
            checkPassphrase EncryptWithScrypt pwd hash `shouldBe` Right ()
        it "compare new implementation with cardano-sl - cardano-wallet password" $ do
            let pwd  = Passphrase @"raw" $ BA.convert $ T.encodeUtf8 "cardano-wallet"
            let hash = Hash $ unsafeFromHex
                    "31347c387c317c2b6a6f747446495a6a566d586f43374c6c54425a576c\
                    \597a425834515177666475467578436b4d485569733d7c78324d646738\
                    \49554a3232507235676531393575445a76583646552b7757395a6a6a2f\
                    \51303054356c654751794279732f7662753367526d726c316c657a7150\
                    \43676d364e6758476d4d2f4b6438343265304b4945773d3d"
            checkPassphrase EncryptWithScrypt pwd hash `shouldBe` Right ()

{-------------------------------------------------------------------------------
                               Properties
-------------------------------------------------------------------------------}

prop_succMaxBoundHardIx :: Property
prop_succMaxBoundHardIx = expectFailure $
    property $ succ (maxBound @(Index 'Hardened _)) `seq` ()

prop_predMinBoundHardIx :: Property
prop_predMinBoundHardIx = expectFailure $
    property $ pred (minBound @(Index 'Hardened _)) `seq` ()

prop_succMaxBoundSoftIx :: Property
prop_succMaxBoundSoftIx = expectFailure $
    property $ succ (maxBound @(Index 'Soft _)) `seq` ()

prop_predMinBoundSoftIx :: Property
prop_predMinBoundSoftIx = expectFailure $
    property $ pred (minBound @(Index 'Soft _)) `seq` ()

prop_roundtripEnumIndexHard :: Index 'WholeDomain 'AccountK -> Property
prop_roundtripEnumIndexHard ix =
    (toEnum . fromEnum) ix === ix .&&. (toEnum . fromEnum . getIndex) ix === ix

prop_roundtripEnumIndexSoft :: Index 'Soft 'AddressK -> Property
prop_roundtripEnumIndexSoft ix =
    (toEnum . fromEnum) ix === ix .&&. (toEnum . fromEnum . getIndex) ix === ix

prop_roundtripXPrv
    :: (PersistPrivateKey (k 'RootK), Eq (k 'RootK XPrv), Show (k 'RootK XPrv))
    => (k 'RootK XPrv, Hash "encryption")
    -> Property
prop_roundtripXPrv xpriv = do
    let xpriv' = (unsafeDeserializeXPrv . serializeXPrv) xpriv
    xpriv' === xpriv

prop_roundtripXPub
    ::  ( PersistPublicKey (k 'AccountK)
        , Eq (k 'AccountK XPub)
        , Show (k 'AccountK XPub)
        )
    => k 'AccountK XPub
    -> Property
prop_roundtripXPub key = do
    let key' = (unsafeDeserializeXPub . serializeXPub) key
    key' === key

prop_passphraseRoundtrip
    :: Passphrase "raw"
    -> Property
prop_passphraseRoundtrip pwd = monadicIO $ liftIO $ do
    hpwd <- encryptPassphrase (preparePassphrase EncryptWithPBKDF2 pwd)
    checkPassphrase EncryptWithPBKDF2 pwd hpwd `shouldBe` Right ()

prop_passphraseRoundtripFail
    :: Passphrase "raw"
    -> Passphrase "raw"
    -> Property
prop_passphraseRoundtripFail p p' =
    p /= p' ==> monadicIO $ liftIO $ do
        hp <- encryptPassphrase (preparePassphrase EncryptWithPBKDF2 p)
        checkPassphrase EncryptWithPBKDF2 p' hp
            `shouldBe` Left ErrWrongPassphrase

prop_passphraseHashMalformed
    :: PassphraseScheme
    -> Passphrase "raw"
    -> Property
prop_passphraseHashMalformed scheme pwd = monadicIO $ liftIO $ do
    checkPassphrase scheme pwd (Hash mempty) `shouldBe` Left ErrWrongPassphrase

prop_passphraseFromScryptRoundtrip
    :: Passphrase "raw"
    -> Property
prop_passphraseFromScryptRoundtrip p = monadicIO $ liftIO $ do
    hp <- encryptPasswordWithScrypt p
    checkPassphrase EncryptWithScrypt p hp `shouldBe` Right ()

prop_passphraseFromScryptRoundtripFail
    :: Passphrase "raw"
    -> Passphrase "raw"
    -> Property
prop_passphraseFromScryptRoundtripFail p p' =
    p /= p' ==> monadicIO $ liftIO $ do
        hp <- encryptPasswordWithScrypt p
        checkPassphrase EncryptWithScrypt p' hp
            `shouldBe` Left ErrWrongPassphrase

-- | xPrvFromStrippedPubXPrv and unXPrvStripPub
prop_strippedPubXPrvRoundtrip1 :: XPrvWithPass -> Property
prop_strippedPubXPrvRoundtrip1 (XPrvWithPass k enc) = do
    let bytes = unXPrvStripPub k
    let Right res = xPrvFromStrippedPubXPrv bytes
    counterexample (show . hex $ bytes) $
        if enc == Passphrase ""
        then label "no passphrase" (res === k)
        else label "passphrase" $ do
            counterexample "shoudn't roundtrip with passphrase"
                $ property $ res /= k

-- | xPrvFromStrippedPubXPrv and unXPrvStripPubCheckRoundtrip
prop_strippedPubXPrvRoundtrip2 :: XPrvWithPass -> Property
prop_strippedPubXPrvRoundtrip2 (XPrvWithPass k enc) = do
    let bytes = left show $ unXPrvStripPubCheckRoundtrip k
    let res = xPrvFromStrippedPubXPrv' <$> bytes
    counterexample (either (const "") (show . hex) bytes) $
        if enc == Passphrase ""
        then label "no passphrase" (res === Right k)
        else label "passphrase" $ do
            case res of
                Right _ ->
                    counterexample "shoudn't roundtrip with passphrase"
                        $ property False
                Left _ ->
                    label "error" True
  where
   -- The input cannot have wrong length, so we discard the possibility of
   -- @Left@.
    xPrvFromStrippedPubXPrv' = either (error . show) id . xPrvFromStrippedPubXPrv

-- | xPrvFromStrippedPubXPrvCheckRoundtrip and unXPrvStripPub
prop_strippedPubXPrvRoundtrip3 :: XPrvWithPass -> Property
prop_strippedPubXPrvRoundtrip3 (XPrvWithPass k enc) = do
    let bytes = unXPrvStripPub k
    let res = xPrvFromStrippedPubXPrvCheckRoundtrip bytes
    counterexample (show $ hex bytes) $
        if enc == Passphrase ""
        then label "no passphrase" (res === Right k)
        else label "passphrase" $ do
            case res of
                Right k' -> label "false success" $ k' /= k
                Left _ -> label "error" True

-- | xPrvFromStrippedPubXPrvCheckRoundtrip and unXPrvStripPubCheckRoundtrip
prop_strippedPubXPrvRoundtrip4 :: XPrvWithPass -> Property
prop_strippedPubXPrvRoundtrip4 (XPrvWithPass k enc) = do
    let bytes = left show $ unXPrvStripPubCheckRoundtrip k
    let res = left show . xPrvFromStrippedPubXPrvCheckRoundtrip =<< bytes
    counterexample (either (const "") (show . hex) bytes) $
        if enc == Passphrase ""
        then label "no passphrase" (res === Right k)
        else label "passphrase" $ do
            case res of
                Right _ ->
                    counterexample "shoudn't roundtrip with passphrase"
                        $ property False
                Left _ ->
                    label "error" True

prop_xPrvFromStrippedPubXPrvLengthRequirement
    :: Unencrypted XPrv
    -> NonNegative Int
    -> Property
prop_xPrvFromStrippedPubXPrvLengthRequirement (Unencrypted k) (NonNegative n) = do
    let f = toStripped >=> (return . BS.take n) >=> fromStripped
    let k' = f k
    -- A reason for writing the test using BS.take n instead of say vectorOf
    -- was guarding against
    -- https://github.com/input-output-hk/cardano-crypto/issues/67
    n < 96 ==> property $ isLeft k'
        & counterexample ("n = " ++ show n)
        & counterexample ("result = " ++ show k')
        & classify (n == 96) "== 96"
        & classify (n < 96) "< 96"
  where
    toStripped = left show . unXPrvStripPubCheckRoundtrip
    fromStripped = left show . xPrvFromStrippedPubXPrvCheckRoundtrip

{-------------------------------------------------------------------------------
                             Arbitrary Instances
-------------------------------------------------------------------------------}

instance Arbitrary (Index 'Soft 'AddressK) where
    shrink _ = []
    arbitrary = arbitraryBoundedEnum

instance Arbitrary (Index 'Hardened 'AccountK) where
    shrink _ = []
    arbitrary = arbitraryBoundedEnum

instance Arbitrary (Index 'WholeDomain 'AddressK) where
    shrink _ = []
    arbitrary = arbitraryBoundedEnum

instance Arbitrary (Index 'WholeDomain 'AccountK) where
    shrink _ = []
    arbitrary = arbitraryBoundedEnum

instance Arbitrary (Passphrase "raw") where
    arbitrary = do
        n <- choose (passphraseMinLength p, passphraseMaxLength p)
        bytes <- T.encodeUtf8 . T.pack <$> replicateM n arbitraryPrintableChar
        return $ Passphrase $ BA.convert bytes
      where p = Proxy :: Proxy "raw"

    shrink (Passphrase bytes)
        | BA.length bytes <= passphraseMinLength p = []
        | otherwise =
            [ Passphrase
            $ BA.convert
            $ B8.take (passphraseMinLength p)
            $ BA.convert bytes
            ]
      where p = Proxy :: Proxy "raw"

instance Arbitrary (Passphrase "encryption") where
    arbitrary = preparePassphrase EncryptWithPBKDF2
        <$> arbitrary @(Passphrase "raw")

instance {-# OVERLAPS #-} Arbitrary (Passphrase "generation") where
    shrink (Passphrase "") = []
    shrink (Passphrase _ ) = [Passphrase ""]
    arbitrary = do
        n <- choose (0, 32)
        InfiniteList bytes _ <- arbitrary
        return $ Passphrase $ BA.convert $ BS.pack $ take n bytes

instance Arbitrary (Hash "encryption") where
    shrink _ = []
    arbitrary = do
        InfiniteList bytes _ <- arbitrary
        return $ Hash $ BS.pack $ take 32 bytes

instance Arbitrary PassphraseScheme where
    arbitrary = genericArbitrary

-- Necessary unsound Show instance for QuickCheck failure reporting
instance Show XPrv where
    show = show . unXPrv

-- Necessary unsound Eq instance for QuickCheck properties
instance Eq XPrv where
    a == b = unXPrv a == unXPrv b

instance Arbitrary (ShelleyKey 'RootK XPrv) where
    shrink _ = []
    arbitrary = genRootKeysSeqWithPass =<< genPassphrase (0, 16)

instance Arbitrary (ShelleyKey 'AccountK XPub) where
    shrink _ = []
    arbitrary = publicKey <$> (genRootKeysSeqWithPass =<< genPassphrase (0, 16))

instance Arbitrary (ShelleyKey 'RootK XPub) where
    shrink _ = []
    arbitrary = publicKey <$> arbitrary

instance Arbitrary (ByronKey 'RootK XPrv) where
    shrink _ = []
    arbitrary = genRootKeysRndWithPass =<< genPassphrase (0, 16)

instance Arbitrary (IcarusKey 'RootK XPrv) where
    shrink _ = []
    arbitrary = genRootKeysIcaWithPass =<< genPassphrase (0, 16)

instance Arbitrary (IcarusKey 'AccountK XPub) where
    shrink _ = []
    arbitrary = publicKey <$> (genRootKeysIcaWithPass =<< genPassphrase (0, 16))

newtype Unencrypted a = Unencrypted { getUnencrypted :: a }
    deriving (Eq, Show)

instance Arbitrary (Unencrypted XPrv) where
    shrink _ = []
    arbitrary = Unencrypted <$> genAnyKeyWithPass mempty

data XPrvWithPass = XPrvWithPass XPrv (Passphrase "encryption")
    deriving (Eq, Show)

instance Arbitrary XPrvWithPass where
    shrink _ = []
    arbitrary = do
        pwd <- oneof
            [ genPassphrase (0, 16)
            , return $ Passphrase ""
            ]
        flip XPrvWithPass pwd <$> genAnyKeyWithPass pwd

genAnyKeyWithPass
    :: Passphrase "encryption"
    -> Gen XPrv
genAnyKeyWithPass pwd = oneof
    [ getRawKey
        <$> genRootKeysSeqWithPass pwd
    , getRawKey
        <$> genRootKeysRndWithPass pwd
    , getRawKey
        <$> genRootKeysIcaWithPass pwd
    ]

genRootKeysSeqWithPass
    :: Passphrase "encryption"
    -> Gen (ShelleyKey depth XPrv)
genRootKeysSeqWithPass encryptionPass = do
    s <- SomeMnemonic <$> genMnemonic @15
    g <- Just . SomeMnemonic <$> genMnemonic @12
    return $ Seq.unsafeGenerateKeyFromSeed (s, g) encryptionPass

genRootKeysRndWithPass
    :: Passphrase "encryption"
    -> Gen (ByronKey 'RootK XPrv)
genRootKeysRndWithPass encryptionPass = Rnd.generateKeyFromSeed
    <$> (SomeMnemonic <$> genMnemonic @12)
    <*> (pure encryptionPass)

genRootKeysIcaWithPass
    :: Passphrase "encryption"
    -> Gen (IcarusKey depth XPrv)
genRootKeysIcaWithPass encryptionPass = Ica.unsafeGenerateKeyFromSeed
    <$> (SomeMnemonic <$> genMnemonic @15)
    <*> (pure encryptionPass)

genPassphrase :: (Int, Int) -> Gen (Passphrase purpose)
genPassphrase range = do
    n <- choose range
    InfiniteList bytes _ <- arbitrary
    return $ Passphrase $ BA.convert $ BS.pack $ take n bytes

genAddress
    :: forall (network :: NetworkDiscriminant). (KnownNetwork network)
    => Gen Address
genAddress = oneof
    [ (\bytes -> Address (BS.pack (addrSingle @network:bytes)))
        <$> vector Seq.publicKeySize
    , (\bytes -> Address (BS.pack (addrGrouped @network:bytes)))
        <$> vector (2*Seq.publicKeySize)
    , (\bytes -> Address (BS.pack (addrAccount @network:bytes)))
        <$> vector Seq.publicKeySize
    ]

genLegacyAddress
    :: Maybe ProtocolMagic
    -> Gen Address
genLegacyAddress pm = do
    bytes <- BS.pack <$> vector 64
    let (Right key) = xpub bytes
    pure $ Address
        $ CBOR.toStrictByteString
        $ CBOR.encodeAddress key
        $ maybe [] (pure . CBOR.encodeProtocolMagicAttr) pm

instance Arbitrary SomeMnemonic where
    arbitrary = SomeMnemonic <$> genMnemonic @12

-- | Encrypt password using Scrypt function with the following parameters:
-- logN = 14
-- r = 8
-- p = 1
-- These parameters are in Scrypt.defaultParams
encryptPasswordWithScrypt
    :: Passphrase "raw"
    -> IO (Hash "encryption")
encryptPasswordWithScrypt p = do
    hashed <- Scrypt.encryptPassIO Scrypt.defaultParams
        $ Scrypt.Pass
        $ CBOR.toStrictByteString
        $ CBOR.encodeBytes
        $ BA.convert passwd
    pure $ Hash $ Scrypt.getEncryptedPass hashed
  where
    (Passphrase passwd) = preparePassphrase EncryptWithScrypt p
