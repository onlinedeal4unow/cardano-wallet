{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.CLISpec
    ( spec
    ) where

import Prelude

import Cardano.CLI
    ( CliKeyScheme (..)
    , CliWalletStyle (..)
    , MnemonicSize (..)
    , Port (..)
    , TxId
    , cli
    , cmdAddress
    , cmdKey
    , cmdMnemonic
    , cmdNetwork
    , cmdStakePool
    , cmdTransaction
    , cmdWallet
    , hGetLine
    , hGetSensitiveLine
    , mapKey
    , newCliKeyScheme
    , xPrvToTextTransform
    )
import Cardano.Wallet.Primitive.AddressDerivation
    ( NetworkDiscriminant (..), XPrv, unXPrv )
import Cardano.Wallet.Primitive.Mnemonic
    ( ConsistentEntropy
    , EntropySize
    , Mnemonic
    , entropyToMnemonic
    , mnemonicToText
    )
import Cardano.Wallet.Unsafe
    ( unsafeMkEntropy )
import Control.Concurrent
    ( forkFinally )
import Control.Concurrent.MVar
    ( newEmptyMVar, putMVar, takeMVar )
import Control.Exception
    ( SomeException, try )
import Control.Monad
    ( mapM_ )
import Data.Proxy
    ( Proxy (..) )
import Data.Text
    ( Text )
import Data.Text.Class
    ( FromText (..), TextDecodingError (..), toText )
import GHC.TypeLits
    ( natVal )
import Options.Applicative
    ( ParserResult (..), columns, execParserPure, prefs, renderFailure )
import System.Exit
    ( ExitCode (..) )
import System.FilePath
    ( (</>) )
import System.IO
    ( Handle, IOMode (..), hClose, openFile, stderr )
import System.IO.Silently
    ( capture_, hCapture_ )
import System.IO.Temp
    ( withSystemTempDirectory )
import Test.Hspec
    ( Spec, describe, expectationFailure, it, shouldBe, shouldStartWith )
import Test.QuickCheck
    ( Arbitrary (..)
    , Gen
    , Large (..)
    , NonEmptyList (..)
    , Property
    , arbitraryBoundedEnum
    , checkCoverage
    , counterexample
    , cover
    , expectFailure
    , forAll
    , genericShrink
    , oneof
    , property
    , vectorOf
    , (.&&.)
    , (===)
    )
import Test.Text.Roundtrip
    ( textRoundtrip )

import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

spec :: Spec
spec = do

    let defaultPrefs = prefs (mempty <> columns 65)

    let parser = cli $ mempty
            <> cmdMnemonic
            <> cmdWallet @'Testnet
            <> cmdTransaction @'Testnet
            <> cmdAddress @'Testnet
            <> cmdStakePool @'Testnet
            <> cmdNetwork @'Testnet
            <> cmdKey


    let shouldStdOut args expected = it (unwords args) $
            case execParserPure defaultPrefs parser args of
                Success x -> capture_ x >>= (`shouldBe` expected)
                CompletionInvoked _ -> expectationFailure
                    "expected parser to show usage but it offered completion"
                Failure failure ->
                    expectationFailure $ "parser failed with: " ++ show failure
    let expectStdErr args expectation = it (unwords args) $
            case execParserPure defaultPrefs parser args of
                Success x ->
                    hCapture_ [stderr] (try @SomeException x) >>= (expectation)
                CompletionInvoked _ -> expectationFailure
                    "expected parser to show usage but it offered completion"
                Failure failure -> do
                    let (str, code) = renderFailure failure ""
                    code `shouldBe` (ExitFailure 1)
                    expectation str
    describe "Specification / Usage Overview" $ do

        let expectationFailure' = flip counterexample False
        let shouldShowUsage args expected = it (unwords args) $
                case execParserPure defaultPrefs parser args of
                    Success _ -> expectationFailure'
                        "expected parser to show usage but it has succeeded"
                    CompletionInvoked _ -> expectationFailure'
                        "expected parser to show usage but it offered completion"
                    Failure failure -> property $
                        let (usage, _) = renderFailure failure mempty
                            msg = "*** Expected:\n" ++ (unlines expected)
                                ++ "*** but actual usage is:\n" ++ usage
                        in counterexample msg $ expected === lines usage

        ["--help"] `shouldShowUsage`
            [ "The CLI is a proxy to the wallet server, which is required for"
            , "most commands. Commands are turned into corresponding API calls,"
            , "and submitted to an up-and-running server. Some commands do not"
            , "require an active server and can be run offline (e.g. 'mnemonic"
            , "generate')."
            , ""
            , "Usage:  COMMAND"
            , "  Cardano Wallet Command-Line Interface (CLI)"
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , ""
            , "Available commands:"
            , "  mnemonic                 Manage mnemonic phrases."
            , "  wallet                   Manage wallets."
            , "  transaction              Manage transactions."
            , "  address                  Manage addresses."
            , "  stake-pool               Manage stake pools."
            , "  network                  Manage network."
            , "  key                      Derive keys from mnemonics."
            ]

        ["mnemonic", "--help"] `shouldShowUsage`
            [ "Usage:  mnemonic COMMAND"
            , "  Manage mnemonic phrases."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , ""
            , "Available commands:"
            , "  generate                 Generate English BIP-0039 compatible"
            , "                           mnemonic words."
            , "  reward-credentials       Derive reward account private key from"
            , "                           a given mnemonic."
            ]

        ["mnemonic", "generate", "--help"] `shouldShowUsage`
            [ "Usage:  mnemonic generate [--size INT]"
            , "  Generate English BIP-0039 compatible mnemonic words."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --size INT               number of mnemonic words to"
            , "                           generate. (default: 15)"
            ]

        ["mnemonic", "reward-credentials", "--help"] `shouldShowUsage`
            [ "Usage:  mnemonic reward-credentials "
            , "  Derive reward account private key from a given mnemonic."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , ""
            , "!!! Only for the Incentivized Testnet !!!"
            ]


        ["key", "--help"] `shouldShowUsage`
            [ "Usage:  key COMMAND"
            , "  Derive keys from mnemonics."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , ""
            , "Available commands:"
            , "  root                     Extract root extended private key from"
            , "                           a mnemonic sentence."
            ]

        ["wallet", "--help"] `shouldShowUsage`
            [ "Usage:  wallet COMMAND"
            , "  Manage wallets."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , ""
            , "Available commands:"
            , "  list                     List all known wallets."
            , "  create                   Create a new wallet using a sequential"
            , "                           address scheme."
            , "  get                      Fetch the wallet with specified id."
            , "  update                   Update a wallet."
            , "  delete                   Deletes wallet with specified wallet"
            , "                           id."
            , "  utxo                     Get UTxO statistics for the wallet"
            , "                           with specified id."
            ]

        ["wallet", "list", "--help"] `shouldShowUsage`
            [ "Usage:  wallet list [--port INT]"
            , "  List all known wallets."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --port INT               port used for serving the wallet"
            , "                           API. (default: 8090)"
            ]

        ["wallet", "create", "--help"] `shouldShowUsage`
            [ "Usage:  wallet create [--port INT] STRING"
            , "                      [--address-pool-gap INT]"
            , "  Create a new wallet using a sequential address scheme."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --port INT               port used for serving the wallet"
            , "                           API. (default: 8090)"
            , "  --address-pool-gap INT   number of unused consecutive addresses"
            , "                           to keep track of. (default: 20)"
            ]

        ["wallet", "get", "--help"] `shouldShowUsage`
            [ "Usage:  wallet get [--port INT] WALLET_ID"
            , "  Fetch the wallet with specified id."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --port INT               port used for serving the wallet"
            , "                           API. (default: 8090)"
            ]

        ["wallet", "update", "--help"] `shouldShowUsage`
            [ "Usage:  wallet update COMMAND"
            , "  Update a wallet."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , ""
            , "Available commands:"
            , "  name                     Update a wallet's name."
            , "  passphrase               Update a wallet's passphrase."
            ]

        ["wallet", "delete", "--help"] `shouldShowUsage`
            [ "Usage:  wallet delete [--port INT] WALLET_ID"
            , "  Deletes wallet with specified wallet id."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --port INT               port used for serving the wallet"
            , "                           API. (default: 8090)"
            ]

        ["wallet", "utxo", "--help"] `shouldShowUsage`
            [ "Usage:  wallet utxo [--port INT] WALLET_ID"
            , "  Get UTxO statistics for the wallet with specified id."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --port INT               port used for serving the wallet"
            , "                           API. (default: 8090)"
            ]

        ["transaction", "--help"] `shouldShowUsage`
            [ "Usage:  transaction COMMAND"
            , "  Manage transactions."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , ""
            , "Available commands:"
            , "  create                   Create and submit a new transaction."
            , "  fees                     Estimate fees for a transaction."
            , "  list                     List the transactions associated with"
            , "                           a wallet."
            , "  submit                   Submit an externally-signed"
            , "                           transaction."
            , "  forget                   Forget a pending transaction with"
            , "                           specified id."
            ]

        ["transaction", "create", "--help"] `shouldShowUsage`
            [ "Usage:  transaction create [--port INT] WALLET_ID"
            , "                           --payment PAYMENT"
            , "  Create and submit a new transaction."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --port INT               port used for serving the wallet"
            , "                           API. (default: 8090)"
            , "  --payment PAYMENT        address to send to and amount to send"
            , "                           separated by @, e.g."
            , "                           '<amount>@<address>'"
            ]

        ["transaction", "fees", "--help"] `shouldShowUsage`
            [ "Usage:  transaction fees [--port INT] WALLET_ID --payment PAYMENT"
            , "  Estimate fees for a transaction."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --port INT               port used for serving the wallet"
            , "                           API. (default: 8090)"
            , "  --payment PAYMENT        address to send to and amount to send"
            , "                           separated by @, e.g."
            , "                           '<amount>@<address>'"
            ]

        ["transaction", "list", "--help"] `shouldShowUsage`
            [ "Usage:  transaction list [--port INT] WALLET_ID [--start TIME]"
            , "                         [--end TIME] [--order ORDER]"
            , "  List the transactions associated with a wallet."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --port INT               port used for serving the wallet"
            , "                           API. (default: 8090)"
            , "  --start TIME             start time (ISO 8601 date-and-time"
            , "                           format: basic or extended, e.g."
            , "                           2012-09-25T10:15:00Z)."
            , "  --end TIME               end time (ISO 8601 date-and-time"
            , "                           format: basic or extended, e.g."
            , "                           2016-11-21T10:15:00Z)."
            , "  --order ORDER            specifies a sort order, either"
            , "                           'ascending' or 'descending'."
            ]

        ["transaction", "submit", "--help"] `shouldShowUsage`
            [ "Usage:  transaction submit [--port INT] BINARY_BLOB"
            , "  Submit an externally-signed transaction."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --port INT               port used for serving the wallet"
            , "                           API. (default: 8090)"
            , "  BINARY_BLOB              hex-encoded binary blob of"
            , "                           externally-signed transaction."
            ]

        ["transaction", "forget", "--help"] `shouldShowUsage`
            [ "Usage:  transaction forget [--port INT] WALLET_ID TRANSACTION_ID"
            , "  Forget a pending transaction with specified id."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --port INT               port used for serving the wallet"
            , "                           API. (default: 8090)"
            ]

        ["address", "--help"] `shouldShowUsage`
            [ "Usage:  address COMMAND"
            , "  Manage addresses."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , ""
            , "Available commands:"
            , "  list                     List all known addresses of a given"
            , "                           wallet."
            ]

        ["address", "list", "--help"] `shouldShowUsage`
            [ "Usage:  address list [--port INT] [--state STRING] WALLET_ID"
            , "  List all known addresses of a given wallet."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --port INT               port used for serving the wallet"
            , "                           API. (default: 8090)"
            , "  --state STRING           only addresses with the given state:"
            , "                           either 'used' or 'unused'."
            ]

        ["stake-pool", "list", "--help"] `shouldShowUsage`
            [ "Usage:  stake-pool list [--port INT]"
            , "  List all known stake pools."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --port INT               port used for serving the wallet"
            , "                           API. (default: 8090)"
            ]

        ["network", "--help"] `shouldShowUsage`
            [ "Usage:  network COMMAND"
            , "  Manage network."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , ""
            , "Available commands:"
            , "  information              View network information."
            , "  parameters               View network parameters."
            ]

        ["network", "information", "--help"] `shouldShowUsage`
            [ "Usage:  network information [--port INT]"
            , "  View network information."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --port INT               port used for serving the wallet"
            , "                           API. (default: 8090)"
            ]

        ["network", "parameters", "--help"] `shouldShowUsage`
            [ "Usage:  network parameters [--port INT] EPOCH_NUMBER"
            , "  View network parameters."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --port INT               port used for serving the wallet"
            , "                           API. (default: 8090)"
            , "  EPOCH_NUMBER             epoch number parameter or 'latest'"
            ]

        ["key", "root", "--help"] `shouldShowUsage`
            [ "Usage:  key root --wallet-style WALLET_STYLE MNEMONIC_WORD..."
            , "  Extract root extended private key from a mnemonic sentence."
            , ""
            , "Available options:"
            , "  -h,--help                Show this help text"
            , "  --wallet-style WALLET_STYLE"
            , "                           Any of the following:"
            , "                             icarus (15 words)"
            , "                             trezor (12, 15, 18, 21 or 24 words)"
            , "                             ledger (12, 15, 18, 21 or 24 words)"
            ]

    describe "Can perform roundtrip textual encoding & decoding" $ do
        textRoundtrip $ Proxy @(Port "test")
        textRoundtrip $ Proxy @MnemonicSize
        textRoundtrip $ Proxy @CliWalletStyle

    describe "Transaction ID decoding from text" $ do

        it "Should produce a user-friendly error message on failing to \
            \decode a transaction ID." $ do

            let err = TextDecodingError
                    "A transaction ID should be a hex-encoded string of 64 \
                    \characters."

            fromText @TxId "not-a-transaction-id" `shouldBe` Left err

    describe "Port decoding from text" $ do
        let err = TextDecodingError
                $ "expected a TCP port number between "
                <> show (getPort minBound)
                <> " and "
                <> show (getPort maxBound)

        it "decode valid numbers to TCP Port, fail otherwise" $ checkCoverage $
            \(Large p) ->
                let
                    result :: Either TextDecodingError (Port "")
                    result = fromText (toText p)
                in
                        if p >= getPort minBound && p <= getPort maxBound
                            then cover 3 True "Right" $ result === Right (Port p)
                            else cover 90 True "Left" $ result === Left err

        mapM_ (\p -> it (T.unpack p) $ fromText @(Port "") p === Left err)
            [ "not-a-int"
            , "14.42"
            , ""
            , "[]"
            , "0x1337"
            , "0"
            ]

    describe "getLine" $ do
        it "Normal usage" $ test hGetLine $ GetLineTest
            { prompt = "Prompt: "
            , input = "warrior toilet word\n"
            , expectedStdout = "Prompt: "
            , expectedResult = "warrior toilet word" :: Text
            }

        it "Parser with failure" $ test hGetLine $ GetLineTest
            { prompt = "Prompt: "
            , input = "patate\n14\n"
            , expectedStdout =
                "Prompt: Int is an \
                \integer number between "
                <> T.pack (show $ minBound @Int)
                <> " and "
                <> T.pack (show $ maxBound @Int)
                <> ".\nPrompt: "
            , expectedResult = 14 :: Int
            }

    describe "getSensitiveLine" $ do
        it "Normal usage" $ test hGetSensitiveLine $ GetLineTest
            { prompt = "Prompt: "
            , input = "password\n"
            , expectedStdout = "Prompt: ********\n"
            , expectedResult = "password" :: Text
            }

        it "Parser with failure" $ test hGetSensitiveLine $ GetLineTest
            { prompt = "Prompt: "
            , input = "patate\n14\n"
            , expectedStdout =
                "Prompt: ******\nInt is an \
                \integer number between "
                <> T.pack (show $ minBound @Int)
                <> " and "
                <> T.pack (show $ maxBound @Int)
                <> ".\nPrompt: **\n"
            , expectedResult = 14 :: Int
            }

        it "With backspaces" $ test hGetSensitiveLine $ GetLineTest
            { prompt = "Prompt: "
            , input = backspace <> "patate" <> backspace <> backspace <> "14\n"
            , expectedStdout = "Prompt: ******\ESC[1D \ESC[1D\ESC[1D \ESC[1D**\n"
            , expectedResult = "pata14" :: Text
            }

    let mw15 = words "message mask aunt wheel ten maze between tomato slow \
                     \analyst ladder such report capital produce"
    let mw12 = words "broccoli side goddess shaft alarm victory sheriff \
                     \combine birth deny train outdoor"
    describe "key derivation from mnemonics" $ do
        (["key", "root", "--wallet-style", "icarus"] ++ mw15) `shouldStdOut`
            "00aa5f5f364980f4ac6295fd0fbf65643390d6bb1cf76536c2ebb02713c8ba50d8\
            \903bee774b7bf8678ea0d6fded6d876db3b42bef687640cc514eb73f767537a8c7\
            \54f89bc9cc83533eab257d7c94625c95f0d749710428f5aa2404eeb6499b\n"
        (["key", "root", "--wallet-style", "trezor"] ++ mw15) `shouldStdOut`
            "00aa5f5f364980f4ac6295fd0fbf65643390d6bb1cf76536c2ebb02713c8ba50d8\
            \903bee774b7bf8678ea0d6fded6d876db3b42bef687640cc514eb73f767537a8c7\
            \54f89bc9cc83533eab257d7c94625c95f0d749710428f5aa2404eeb6499b\n"
        (["key", "root", "--wallet-style", "ledger"] ++ mw15) `shouldStdOut`
            "003a914372e711b910a75b87e98695929b6960bd5380cfd766b572ea844ea14080\
            \9eb7ad13f798d06ce550a9f6c48dd2151db4593e67dbd2821d75378c7350f1366b\
            \85e0be9cdec2213af2084d462cc11e85c215e0f003acbeb996567e371502\n"

    describe "key derivation (negative tests)" $ do
        (["key", "root", "--wallet-style", "icarus"] ++ mw12) `expectStdErr`
            (`shouldBe` "Invalid number of words: 15 words are expected.\n")

        (["key", "root", "--wallet-style", "icarus"]) `expectStdErr`
            (`shouldStartWith` "Missing: MNEMONIC_WORD...")

        let shrug = "¯\\_(ツ)_/¯"
        (["key", "root", "--wallet-style", "icarus"] ++ (replicate 15 shrug))
            `expectStdErr` (`shouldBe`
            "Found an unknown word not present in the pre-defined dictionary. \
            \The full dictionary is available here:\
            \ https://github.com/input-output-hk/cardano-wallet/tree/master/spe\
            \cifications/mnemonic/english.txt\n")

    describe "CliKeyScheme" $ do
        it "all allowedWordLengths are supported"
            $ property prop_allowedWordLengthsAllWork

        it "scheme == scheme (reflexivity)" $ property $ \s ->
            propCliKeySchemeEquality
                (newCliKeyScheme s)
                (newCliKeyScheme s)

        -- This tests provides a stronger guarantee than merely knowing that
        -- unsafeHexTextToXPrv and xPrvToHexText roundtrips.
        it "scheme == mapKey (fromHex . toHex) scheme"
            $ property prop_roundtripCliKeySchemeKeyViaHex

        it "random /= icarus" $ do
            expectFailure $ propCliKeySchemeEquality
                (newCliKeyScheme Ledger)
                (newCliKeyScheme Icarus)

  where
    backspace :: Text
    backspace = T.singleton (toEnum 127)

prop_roundtripCliKeySchemeKeyViaHex :: CliWalletStyle -> Property
prop_roundtripCliKeySchemeKeyViaHex style =
            propCliKeySchemeEquality
                (newCliKeyScheme style)
                (mapKey (inverse xPrvToTextTransform)
                    . mapKey xPrvToTextTransform
                    $ newCliKeyScheme style)
  where
    inverse (a, b) = (b, a)

prop_allowedWordLengthsAllWork :: CliWalletStyle -> Property
prop_allowedWordLengthsAllWork style = do
    (forAll (genAllowedMnemonic s) propCanRetrieveRootKey)
  where
    s :: CliKeyScheme XPrv (Either String)
    s = newCliKeyScheme style

    propCanRetrieveRootKey :: [Text] -> Property
    propCanRetrieveRootKey mw = case mnemonicToRootKey s mw of
        Right _ -> property True
        Left e -> counterexample
            (show (length mw) ++ " words, failed with: " ++ e)
            (property False)

propCliKeySchemeEquality
    :: CliKeyScheme XPrv (Either String)
    -> CliKeyScheme XPrv (Either String)
    -> Property
propCliKeySchemeEquality s1 s2 = do
    (forAll (genAllowedMnemonic s1) propSameMnem)
    .&&.
    (allowedWordLengths s1) === (allowedWordLengths s2)
  where
    propSameMnem :: [Text] -> Property
    propSameMnem mw = (mnemonicToRootKey s1 mw) === (mnemonicToRootKey s2 mw)

genAllowedMnemonic :: CliKeyScheme key m -> Gen [Text]
genAllowedMnemonic s = oneof (map genMnemonicOfSize $ allowedWordLengths s)

genMnemonicOfSize :: Int -> Gen [Text]
genMnemonicOfSize = \case
    12 -> mnemonicToText <$> genMnemonic @12
    15 -> mnemonicToText <$> genMnemonic @15
    18 -> mnemonicToText <$> genMnemonic @18
    21 -> mnemonicToText <$> genMnemonic @21
    24 -> mnemonicToText <$> genMnemonic @24
    n  -> error $ "when this test was written, " ++ show n ++
            " was not a valid length of a mnemonic"

instance Show XPrv where
    show = show . unXPrv

instance Eq XPrv where
    a == b = unXPrv a == unXPrv b

genMnemonic
    :: forall mw ent csz.
     ( ConsistentEntropy ent mw csz
     , EntropySize mw ~ ent
     )
    => Gen (Mnemonic mw)
genMnemonic = do
        let n = fromIntegral (natVal $ Proxy @(EntropySize mw)) `div` 8
        bytes <- BS.pack <$> vectorOf n arbitrary
        let ent = unsafeMkEntropy @(EntropySize mw) bytes
        return $ entropyToMnemonic ent

{-------------------------------------------------------------------------------
                                hGetSensitiveLine
-------------------------------------------------------------------------------}

data GetLineTest a = GetLineTest
    { prompt :: Text
    , input :: Text
    , expectedStdout :: Text
    , expectedResult :: a
    }

test
    :: (FromText a, Show a, Eq a)
    =>  (  (Handle, Handle)
        -> Text
        -> (Text -> Either TextDecodingError a)
        -> IO (a, Text)
        )
    -> GetLineTest a
    -> IO ()
test fn (GetLineTest prompt_ input_ output expected) =
    withSystemTempDirectory "cardano-wallet-cli" $ \dir -> do
        -- Setup
        let fstdin = dir </> "stdin"
        let fstdout = dir </> "stdout"
        TIO.writeFile fstdin input_ *> writeFile fstdout mempty
        stdin <- openFile fstdin ReadWriteMode
        stdout <- openFile fstdout ReadWriteMode

        -- Action
        mvar <- newEmptyMVar
        let action = fn (stdin, stdout) prompt_ fromText
        _ <- forkFinally action (handler mvar)
        res <- takeMVar mvar
        hClose stdin *> hClose stdout
        content <- TIO.readFile fstdout

        -- Expectations
        (fst <$> res) `shouldBe` Just expected
        content `shouldBe` output
  where
    handler mvar = \case
        Left _ ->
            putMVar mvar Nothing
        Right a ->
            putMVar mvar (Just a)

{-------------------------------------------------------------------------------
                               Arbitrary Instances
-------------------------------------------------------------------------------}

instance Arbitrary MnemonicSize where
    arbitrary = arbitraryBoundedEnum
    shrink = genericShrink

instance Arbitrary CliWalletStyle where
    arbitrary = arbitraryBoundedEnum
    shrink = genericShrink

instance Arbitrary (Port "test") where
    arbitrary = arbitraryBoundedEnum
    shrink p
        | p == minBound = []
        | otherwise = [pred p]
