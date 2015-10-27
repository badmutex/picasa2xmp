{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}

module Main where

import System.Directory
import System.FilePath

import Control.Monad
import qualified Data.Text as T
import Data.Text (Text)
import Data.Ini
import Data.List
import qualified Data.HashMap.Strict as H
import Data.HashMap.Strict (HashMap)
import Data.Monoid
import Data.Either
import Data.Maybe
import System.Process

class ToText a where toText :: a -> Text

instance ToText Int where toText = T.pack . show

-- -------------------------------------------------- Exiv / XMP

list :: a -> [a]
list a = [a]

flattenXmpValue :: XMPValue -> [Text]
flattenXmpValue v = maybe [] (list . toText) (valueType v)  ++ txt
    where txt = if T.null $ valueText v
                then []
                else [valueText v]

eval :: Exiv2ModifyCommand -> String
eval c = T.unpack 
         $ T.intercalate " " 
         $ case c of
             SET k v -> ["set", unKey k] ++ flattenXmpValue v
             ADD k v -> ["add", unKey k] ++ flattenXmpValue v
             DEL k   -> ["del", unKey k]

data Exiv2ModifyCommand = SET XMPKey XMPValue
                        | ADD XMPKey XMPValue
                        | DEL XMPKey
                          deriving (Eq, Show)

newtype XMPKey = XMPKey {unKey :: Text}
    deriving (Eq, Show)

instance ToText XMPKey where toText (XMPKey t) = t

data XMPType = XmpText
             | XmpAlt
             | XmpBag
             | XmpSeq
             | LangAlt
               deriving (Eq, Show)

instance ToText XMPType where toText = T.pack . show

data XMPValue = XMPValue {valueType :: (Maybe XMPType) , valueText :: Text}
              deriving (Eq, Show)

instance ToText XMPValue where
    toText (XMPValue t v) =
        case t of
          Just t' -> toText t' <> " " <> v
          Nothing -> v

cmd2Args :: Exiv2ModifyCommand -> Text
cmd2Args (SET k v) = T.intercalate " " ["set", toText k, toText v]
cmd2Args (ADD k v) = T.intercalate " " ["add", toText k, toText v]
cmd2Args (DEL k  ) = T.intercalate " " ["del", toText k]

xmp :: Text -- ^ tag name
    -> XMPType -- ^ type
    -> Text -- ^ value
    -> (XMPKey, XMPValue)
xmp tag typ val = ( (XMPKey tag)
                  , (XMPValue (Just typ)) val
                  )

at :: Text -> Int -> Text
at t i = t <> "[" <> toText i <> "]"

dc_caption :: Text -> (XMPKey, XMPValue)
dc_caption = xmp "Xmp.dc.description" LangAlt

dc_title :: Text -> (XMPKey, XMPValue)
dc_title = xmp "Xmp.dc.title" LangAlt

xmp_Label :: Text -> (XMPKey, XMPValue)
xmp_Label = xmp "Xmp.xmp.Label" XmpText

xmp_Rating :: Int -> (XMPKey, XMPValue)
xmp_Rating = xmp "XMP.xmp.Rating" XmpText . T.pack . show

lr_HierarchicalSubject :: Text -> (XMPKey, XMPValue)
lr_HierarchicalSubject = xmp "Xmp.lr.HierarchicalSubject" XmpText

lr_hierarchicalSubject_composit :: Int -> Text -> (XMPKey, XMPValue)
lr_hierarchicalSubject_composit i = xmp ("Xmp.lr.hierarchicalSubject["<> toText i <> "]") XmpText

-- -------------------------------------------------- Picasa


data PicasaAlbum = PicasaAlbum {
      albumId :: Text
    , albumName :: Text
    } deriving (Eq, Show)


data PicasaMetadata = PicasaMetadata {
      star :: Bool
    , albums :: [PicasaAlbum]
    } deriving (Eq, Show)

data PicasaImage = PicasaImage {
      imagePath :: FilePath
    , metadata :: PicasaMetadata
    } deriving (Eq, Show)

-- | Return `Left` if there is no metadata for the file, else `Right`
picasaImage :: Ini -> FilePath -> Either String PicasaImage
picasaImage ini path = do
  let name = T.pack $ takeFileName path

  -- star
  let isStarred = either (const False) (=="yes") $ lookupValue name "star" ini

  -- albums
  albumIds <- T.splitOn "," <$> lookupValue name "albums" ini
  albums <- mapM (picasaAlbum ini) albumIds

  let metadata = PicasaMetadata isStarred albums
  return $ PicasaImage path metadata

picasaAlbum :: Ini -> Text -> Either String PicasaAlbum
picasaAlbum ini aid = PicasaAlbum <$> pure aid <*> name
    where name = lookupValue (".album:"<>aid) "name" ini


loadPicasaImage :: FilePath -> IO [PicasaImage]
loadPicasaImage picasa_ini_path = do
  path <- makeAbsolute picasa_ini_path
  let dirname = takeDirectory path
  files <- map (dirname</>) 
           . filter (not . (`elem` [".", "..", ".picasa.ini", ".picasaoriginals"]))
          <$> getDirectoryContents dirname
  ini <- readIniFile path
  return $ rights $ either fail (\ini' -> map (picasaImage ini') files) ini

picasaStar2cmd :: PicasaImage -> Maybe [Exiv2ModifyCommand]
picasaStar2cmd p = 
    if star $ metadata p
    then Just [uncurry SET $ xmp_Rating 5]
    else Nothing

picasaAlbums2cmd :: LightroomSettings -> PicasaImage -> Maybe [Exiv2ModifyCommand]
picasaAlbums2cmd settings = wrapMaybe . concatMap mk . albums . metadata
    where
      mk :: PicasaAlbum -> [Exiv2ModifyCommand]
      mk a = 
        let tags = [albumPrefix settings, albumName a]
            kwds = T.intercalate (hierarchySeparator settings) tags : tags
        in concat [
             [uncurry SET $ xmp "Xmp.lr.HierarchicalSubject" XmpText (albumPrefix settings)]
           , [uncurry SET $ xmp "Xmp.dc.subject" XmpBag ""]
           , zipWith (\ix tag -> uncurry SET $ xmp ("Xmp.dc.subject" `at` ix) XmpText tag) [1..] tags
           , [uncurry SET $ xmp "Xmp.lr.hierarchicalSubject" XmpBag ""]
           , zipWith (\ix kwd -> uncurry SET $ xmp ("Xmp.lr.hierarchicalSubject" `at` ix) XmpText kwd) [1..] kwds
           ]

      wrapMaybe :: [a] -> Maybe [a]
      wrapMaybe l = if null l then Nothing else Just l


data LightroomSettings = LightroomSettings {
      albumPrefix :: Text
    , hierarchySeparator :: Text
    } deriving (Eq, Show)

defaultSettings :: LightroomSettings
defaultSettings = LightroomSettings {
                    albumPrefix = "album"
                  , hierarchySeparator = "|"
                  }

picasa2cmd :: LightroomSettings -> PicasaImage -> (FilePath, [Exiv2ModifyCommand])
picasa2cmd s p = (,) (imagePath p) 
                 $ concat $ catMaybes [
                   picasaStar2cmd p
                 , picasaAlbums2cmd s p
                 ]


run1cmd :: FilePath -> Exiv2ModifyCommand -> IO ()
run1cmd imagePath cmd = run
    where
      args = ["-M" <> eval cmd, imagePath]
      run = callProcess "exiv2" args

main :: IO ()
main = putStrLn "Hello"