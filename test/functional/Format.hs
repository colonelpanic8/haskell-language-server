{-# LANGUAGE CPP               #-}
{-# LANGUAGE OverloadedStrings #-}
module Format (tests) where

import           Control.Lens                ((^.))
import           Control.Monad.IO.Class
import qualified Data.ByteString.Lazy        as BS
import           Data.Functor                (void)
import qualified Data.Text                   as T
import qualified Data.Text.Encoding          as T
import qualified Data.Text.IO                as T
import           Ide.Types
import qualified Language.LSP.Protocol.Lens  as L
import           Language.LSP.Protocol.Types
import           Language.LSP.Test
import           Test.Hls
import           Test.Hls.Command
import           Test.Hls.Flags              (requiresFloskellPlugin,
                                              requiresOrmoluPlugin)

tests :: TestTree
tests = testGroup "format document" [
    requiresOrmoluPlugin $ goldenGitDiff "works" "test/testdata/format/Format.formatted_document.hs" $ runSession hlsCommand fullCaps "test/testdata/format" $ do
        doc <- openDoc "Format.hs" "haskell"
        formatDoc doc (FormattingOptions 2 True Nothing Nothing Nothing)
        BS.fromStrict . T.encodeUtf8 <$> documentContents doc
    , requiresOrmoluPlugin $ goldenGitDiff "works with custom tab size" "test/testdata/format/Format.formatted_document_with_tabsize.hs" $ runSession hlsCommand fullCaps "test/testdata/format" $ do
        doc <- openDoc "Format.hs" "haskell"
        formatDoc doc (FormattingOptions 5 True Nothing Nothing Nothing)
        BS.fromStrict . T.encodeUtf8 <$> documentContents doc
    , rangeTests
    , providerTests
    ]

rangeTests :: TestTree
rangeTests = requiresOrmoluPlugin $ testGroup "format range" [
    goldenGitDiff "works" "test/testdata/format/Format.formatted_range.hs" $ runSession hlsCommand fullCaps "test/testdata/format" $ do
        doc <- openDoc "Format.hs" "haskell"
        formatRange doc (FormattingOptions 2 True Nothing Nothing Nothing) (Range (Position 5 0) (Position 7 10))
        BS.fromStrict . T.encodeUtf8 <$> documentContents doc
    , goldenGitDiff "works with custom tab size" "test/testdata/format/Format.formatted_range_with_tabsize.hs" $ runSession hlsCommand fullCaps "test/testdata/format" $ do
        doc <- openDoc "Format.hs" "haskell"
        formatRange doc (FormattingOptions 5 True Nothing Nothing Nothing) (Range (Position 8 0) (Position 11 19))
        BS.fromStrict . T.encodeUtf8 <$> documentContents doc
    ]

providerTests :: TestTree
providerTests = testGroup "formatting provider" [
    testCase "respects none" $ runSessionWithConfig (formatConfig "none") hlsCommand fullCaps "test/testdata/format" $ do
        void configurationRequest
        doc <- openDoc "Format.hs" "haskell"
        resp <- request SMethod_TextDocumentFormatting $ DocumentFormattingParams Nothing doc (FormattingOptions 2 True Nothing Nothing Nothing)
        liftIO $ case resp ^. L.result of
          result@(Left (ResponseError reason message Nothing)) -> case reason of
            (InR ErrorCodes_MethodNotFound) -> pure () -- No formatter
            (InR ErrorCodes_InvalidRequest) | "No plugin enabled for SMethod_TextDocumentFormatting" `T.isPrefixOf` message -> pure ()
            _ -> assertFailure $ "strange response from formatting provider:" ++ show result
          result -> assertFailure $ "strange response from formatting provider:" ++ show result

    , requiresOrmoluPlugin . requiresFloskellPlugin $ testCase "can change on the fly" $ runSessionWithConfig (formatConfig "none") hlsCommand fullCaps "test/testdata/format" $ do
        void configurationRequest
        formattedOrmolu <- liftIO $ T.readFile "test/testdata/format/Format.ormolu.formatted.hs"
        formattedFloskell <- liftIO $ T.readFile "test/testdata/format/Format.floskell.formatted.hs"
        formattedOrmoluPostFloskell <- liftIO $ T.readFile "test/testdata/format/Format.ormolu_post_floskell.formatted.hs"

        doc <- openDoc "Format.hs" "haskell"

        setHlsConfig (formatLspConfig "ormolu")
        formatDoc doc (FormattingOptions 2 True Nothing Nothing Nothing)
        documentContents doc >>= liftIO . (@?= formattedOrmolu)

        setHlsConfig (formatLspConfig "floskell")
        formatDoc doc (FormattingOptions 2 True Nothing Nothing Nothing)
        documentContents doc >>= liftIO . (@?= formattedFloskell)

        setHlsConfig (formatLspConfig "ormolu")
        formatDoc doc (FormattingOptions 2 True Nothing Nothing Nothing)
        documentContents doc >>= liftIO . (@?= formattedOrmoluPostFloskell)
    ]

formatLspConfig :: T.Text -> Config
formatLspConfig provider = def { formattingProvider = provider }

formatConfig :: T.Text -> SessionConfig
formatConfig provider = defaultConfig { lspConfig = hlsConfigToClientConfig (formatLspConfig provider), ignoreConfigurationRequests = False }
