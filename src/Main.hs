--------------------------------------------------------------------------------
{-# LANGUAGE OverloadedStrings #-}
import Control.Applicative (Alternative (..), (<$>))
import Control.Monad (filterM)
import Data.List (intersperse, isSuffixOf)
import Data.List.Split (splitOn)
import Data.Monoid (mappend)
import Hakyll
import Metaplasm.Config
import Metaplasm.Tags
import System.FilePath (combine, splitExtension, takeFileName)
import Text.Pandoc.Options (writerHtml5)


--------------------------------------------------------------------------------
hakyllConf :: Configuration
hakyllConf = defaultConfiguration
  { deployCommand = "rsync -ave 'ssh' _site/* meta.plasm.us:www/meta.plasm.us"
  }

siteConf :: SiteConfiguration
siteConf = SiteConfiguration
  { siteRoot = "http://meta.plasm.us/"
  , siteGaId = "UA-36422511-1"
  }

feedConf :: String -> FeedConfiguration
feedConf title = FeedConfiguration
  { feedTitle = "meta.plasm.us: " ++ title
  , feedDescription = "Mostly Scala, some computational humanities"
  , feedAuthorName = "Travis Brown"
  , feedAuthorEmail = "travisrobertbrown@gmail.com"
  , feedRoot = "http://meta.plasm.us"
  }

--------------------------------------------------------------------------------
main :: IO ()
main = hakyllWith hakyllConf $ do
  let engineConf = defaultEngineConfiguration
  let writerOptions = defaultHakyllWriterOptions { writerHtml5 = True }

  let pandocHtml5Compiler =
        pandocCompilerWith defaultHakyllReaderOptions writerOptions

  tags <- buildTags "content/posts/*" (fromCapture "tags/*/index.html")

  match "images/*.png" $ do
    route idRoute
    compile copyFileCompiler

  match (fromList $ vendorScriptFiles engineConf) $ do
    route $ customRoute (combine "js/vendor" . takeFileName . toFilePath)
    compile copyFileCompiler

  match (fromList $ lessFiles engineConf) $ do
    route $ setExtension "css"
    compile $ getResourceString
      >>= withItemBody 
        (unixFilter (lessCommand engineConf) $ "-" : (lessOptions engineConf))

  match "content/about/index.md" $ do
    route $ stripContent `composeRoutes` setExtension "html"
    compile $ pandocHtml5Compiler
      >>= loadAndApplyTemplate "templates/about.html"  siteCtx
      >>= loadAndApplyTemplate "templates/default.html" siteCtx
      >>= relativizeUrls
      >>= deIndexUrls

  tagsRules tags $ \tag pattern -> do
    let title = "Posts tagged " ++ tag

    route idRoute
    compile $ do
      list <- postList tags (\t -> recentFirst t >>= filterM (fmap (elem tag) . getTags . itemIdentifier))
      makeItem ""
        >>= loadAndApplyTemplate "templates/tag-posts.html"
              (constField "tag" tag `mappend`
               constField "posts" list `mappend`
               siteCtx)
        >>= loadAndApplyTemplate "templates/default.html" (constField "title" title `mappend` siteCtx)
        >>= relativizeUrls
        >>= deIndexUrls

    version "rss" $ do
      let feedCtx = postCtx tags `mappend` bodyField "description"
      route $ setExtension "xml"
      compile $ loadAllSnapshots pattern "content"
        >>= fmap (take 10) . recentFirst
        >>= renderAtom (feedConf title) feedCtx

  match "content/posts/*" $ do
    route $ directorizeDate `composeRoutes` stripContent `composeRoutes` setExtension "html"
    compile $ pandocHtml5Compiler
        >>= loadAndApplyTemplate "templates/post.html" (postCtx tags)
        >>= saveSnapshot "content"
        >>= loadAndApplyTemplate "templates/default.html" (postCtx tags)
        >>= relativizeUrls
        >>= deIndexUrls

  create ["archive.html"] $ do
    route idRoute
    compile $ do
      let archiveCtx =
            field "posts" (\_ -> postList tags recentFirst) `mappend`
            constField "title" "Archives" `mappend` siteCtx

      makeItem ""
        >>= loadAndApplyTemplate "templates/archive.html" archiveCtx
        >>= loadAndApplyTemplate "templates/default.html" archiveCtx
        >>= relativizeUrls

  match "content/index.html" $ do
    route stripContent
    compile $ do
      tpl <- loadBody "templates/post-item-full.html"
      body <- readTemplate . itemBody <$> getResourceBody
      loadAllSnapshots "content/posts/*" "content"
        >>= fmap (take 10) . recentFirst
        >>= applyTemplateList tpl (postCtx tags)
        >>= makeItem
        >>= applyTemplate body (siteCtx `mappend` bodyField "posts")
        >>= loadAndApplyTemplate "templates/default.html" siteCtx
        >>= relativizeUrls
        >>= deIndexUrls

  create ["atom.xml"] $ do
    route idRoute
    compile $ do
      let feedCtx = postCtx tags `mappend` bodyField "description"
      posts <- mapM deIndexUrls =<< fmap (take 10) . recentFirst =<<
        loadAllSnapshots "content/posts/*" "content"
      renderAtom (feedConf "blog") feedCtx (posts)

  match "templates/*" $ compile templateCompiler


--------------------------------------------------------------------------------
siteCtx :: Context String
siteCtx =
  constField "root" (siteRoot siteConf) `mappend`
  constField "gaId" (siteGaId siteConf) `mappend`
  defaultContext


--------------------------------------------------------------------------------
postCtx :: Tags -> Context String
postCtx tags =
  deIndexedUrlField "url" `mappend`
  dateField "date" "%e %B %Y" `mappend`
  dateField "datetime" "%Y-%m-%d" `mappend`
  (tagsFieldWith' getTags) "tags" tags `mappend`
  siteCtx


--------------------------------------------------------------------------------
postList :: Tags -> ([Item String] -> Compiler [Item String]) -> Compiler String
postList tags sortFilter = do
  posts <- sortFilter =<< loadAll "content/posts/*"
  itemTpl <- loadBody "templates/post-item.html"
  list <- applyTemplateList itemTpl (postCtx tags) posts
  return list


--------------------------------------------------------------------------------
stripContent :: Routes
stripContent = gsubRoute "content/" $ const ""


--------------------------------------------------------------------------------
directorizeDate :: Routes
directorizeDate = customRoute (\i -> directorize $ toFilePath i)
  where
    directorize path = dirs ++ "/index" ++ ext 
      where
        (dirs, ext) = splitExtension $ concat $ (intersperse "/" date) ++ ["/"] ++ (intersperse "-" rest)
        (date, rest) = splitAt 3 $ splitOn "-" path

stripIndex :: String -> String
stripIndex url = if "index.html" `isSuffixOf` url && elem (head url) "/."
  then take (length url - 10) url else url

deIndexUrls :: Item String -> Compiler (Item String)
deIndexUrls item = return $ fmap (withUrls stripIndex) item

deIndexedUrlField :: String -> Context a
deIndexedUrlField key = field key
  $ fmap (stripIndex . maybe empty toUrl) . getRoute . itemIdentifier


