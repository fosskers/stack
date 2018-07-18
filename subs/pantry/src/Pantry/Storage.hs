{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
module Pantry.Storage
  ( SqlBackend
  , initStorage
  , withStorage
  , storeBlob
  , clearHackageRevisions
  , storeHackageRevision
  , loadHackagePackageVersions
  , loadHackageCabalFile
  , loadLatestCacheUpdate
  , storeCacheUpdate
    -- avoid warnings
  , BlobTableId
  , HackageCabalId
  ) where

import RIO
import qualified RIO.ByteString as B
import Pantry.Types
import Database.Persist
import Database.Persist.Sqlite -- FIXME allow PostgreSQL too
import Database.Persist.TH
import RIO.Orphans ()
import Pantry.StaticSHA256
import qualified RIO.Map as Map
import RIO.Time (UTCTime, getCurrentTime)

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|
BlobTable sql=blob
    hash BlobKey
    size Word
    contents ByteString
    UniqueBlobHash hash
Name sql=package_name
    name PackageNameP
    UniquePackageName name
VersionTable sql=version
    version VersionP
    UniqueVersion version
HackageTarball
    name NameId
    version VersionTableId
    hash StaticSHA256
    size Word
HackageCabal
    name NameId
    version VersionTableId
    revision Revision
    cabal BlobTableId
    UniqueHackage name version revision
CacheUpdate
    time UTCTime
    size Word
    hash StaticSHA256
|]

initStorage
  :: HasLogFunc env
  => FilePath -- ^ storage file
  -> RIO env Storage
initStorage fp = do
  pool <- createSqlitePool (fromString fp) 1
  migrates <- runSqlPool (runMigrationSilent migrateAll) pool
  forM_ migrates $ \mig -> logDebug $ "Migration output: " <> display mig
  pure (Storage pool)

withStorage
  :: (HasPantryConfig env, HasLogFunc env)
  => ReaderT SqlBackend (RIO env) a
  -> RIO env a
withStorage action = do
  Storage pool <- view $ pantryConfigL.to pcStorage
  runSqlPool action pool

getNameId
  :: (HasPantryConfig env, HasLogFunc env)
  => PackageName
  -> ReaderT SqlBackend (RIO env) NameId
getNameId = fmap (either entityKey id) . insertBy . Name . PackageNameP

getVersionId
  :: (HasPantryConfig env, HasLogFunc env)
  => Version
  -> ReaderT SqlBackend (RIO env) VersionTableId
getVersionId = fmap (either entityKey id) . insertBy . VersionTable . VersionP

storeBlob
  :: (HasPantryConfig env, HasLogFunc env)
  => ByteString
  -> ReaderT SqlBackend (RIO env) (BlobTableId, BlobKey)
storeBlob bs = do
  let blobKey = BlobKey $ mkStaticSHA256FromBytes bs
  keys <- selectKeysList [BlobTableHash ==. blobKey] []
  key <-
    case keys of
      [] -> insert BlobTable
              { blobTableHash = blobKey
              , blobTableSize = fromIntegral $ B.length bs
              , blobTableContents = bs
              }
      key:rest -> assert (null rest) (pure key)
  pure (key, blobKey)

clearHackageRevisions
  :: (HasPantryConfig env, HasLogFunc env)
  => ReaderT SqlBackend (RIO env) ()
clearHackageRevisions = deleteWhere ([] :: [Filter HackageCabal])

storeHackageRevision
  :: (HasPantryConfig env, HasLogFunc env)
  => PackageName
  -> Version
  -> BlobTableId
  -> ReaderT SqlBackend (RIO env) ()
storeHackageRevision name version key = do
  nameid <- getNameId name
  versionid <- getVersionId version
  rev <- count
    [ HackageCabalName ==. nameid
    , HackageCabalVersion ==. versionid
    ]
  insert_ HackageCabal
    { hackageCabalName = nameid
    , hackageCabalVersion = versionid
    , hackageCabalRevision = Revision (fromIntegral rev)
    , hackageCabalCabal = key
    }

loadHackagePackageVersions
  :: (HasPantryConfig env, HasLogFunc env)
  => PackageName
  -> ReaderT SqlBackend (RIO env) (Map Version (Map Revision CabalHash))
loadHackagePackageVersions name = do
  nameid <- getNameId name
  -- would be better with esequeleto
  (Map.fromListWith Map.union . map go) <$> rawSql
    "SELECT hackage.revision, version.version, blob.hash, blob.size\n\
    \FROM hackage, version, blob\n\
    \WHERE hackage.name=?\n\
    \AND   hackage.version=version.id\n\
    \AND   hackage.cabal=blob.id"
    [toPersistValue nameid]
  where
    go (Single revision, Single (VersionP version), Single key, Single size) =
      (version, Map.singleton revision (CabalHash key (Just size)))

loadHackageCabalFile
  :: (HasPantryConfig env, HasLogFunc env)
  => PackageName
  -> Version
  -> CabalFileInfo
  -> ReaderT SqlBackend (RIO env) (Maybe ByteString)
loadHackageCabalFile name version cfi = do
  nameid <- getNameId name
  versionid <- getVersionId version
  case cfi of
    CFILatest -> selectFirst
      [ HackageCabalName ==. nameid
      , HackageCabalVersion ==. versionid
      ]
      [Desc HackageCabalRevision] >>= withHackEnt
    CFIRevision rev ->
      getBy (UniqueHackage nameid versionid rev) >>= withHackEnt
    CFIHash (CabalHash (BlobKey -> blobKey) msize) -> do
      ment <- getBy $ UniqueBlobHash blobKey
      pure $ do
        Entity _ bt <- ment
        case msize of
          Nothing -> pure ()
          Just size -> guard $ blobTableSize bt == size -- FIXME report an error if this mismatches?
        -- FIXME also consider validating the ByteString length against blobTableSize
        pure $ blobTableContents bt
  where
    withHackEnt = traverse $ \(Entity _ h) -> do
      Just blob <- get $ hackageCabalCabal h
      pure $ blobTableContents blob

    {-
CacheUpdate
    time UTCTime
    size Word
    hash StaticSHA256
    -}

loadLatestCacheUpdate
  :: (HasPantryConfig env, HasLogFunc env)
  => ReaderT SqlBackend (RIO env) (Maybe (Word, StaticSHA256))
loadLatestCacheUpdate =
    fmap go <$> selectFirst [] [Desc CacheUpdateTime]
  where
    go (Entity _ cu) = (cacheUpdateSize cu, cacheUpdateHash cu)

storeCacheUpdate
  :: (HasPantryConfig env, HasLogFunc env)
  => Word
  -> StaticSHA256
  -> ReaderT SqlBackend (RIO env) ()
storeCacheUpdate size hash' = do
  now <- getCurrentTime
  insert_ CacheUpdate
    { cacheUpdateTime = now
    , cacheUpdateSize = size
    , cacheUpdateHash = hash'
    }