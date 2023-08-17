module Development.IDE.Core.Dependencies
  ( indexDependencyHieFiles
  ) where

import           Control.Concurrent.STM         (atomically)
import           Control.Concurrent.STM.TQueue  (writeTQueue)
import           Control.Monad                  (unless, void)
import           Data.Foldable                  (traverse_)
import qualified Data.Map                       as Map
import           Data.Maybe                     (isNothing)
import           Data.Set                       (Set)
import qualified Data.Set                       as Set
import           Development.IDE.Core.Compile   (indexHieFile)
import           Development.IDE.Core.Rules     (HieFileCheck (..), Log,
                                                 checkHieFile)
import           Development.IDE.Core.Shake     (HieDbWriter (indexQueue),
                                                 ShakeExtras (hiedbWriter, lspEnv, withHieDb))
import qualified Development.IDE.GHC.Compat     as GHC
import           Development.IDE.Types.Location (NormalizedFilePath,
                                                 toNormalizedFilePath')
import           HieDb                          (SourceFile (FakeFile),
                                                 lookupPackage,
                                                 removeDependencySrcFiles)
import           Ide.Logger                     (Recorder, WithPriority)
import           Ide.Types                      (hlsDirectory)
import           Language.LSP.Server            (resRootPath)
import           System.Directory               (doesDirectoryExist)
import           System.FilePath                ((<.>), (</>))

newtype Package = Package GHC.UnitInfo deriving Eq
instance Ord Package where
  compare (Package u1) (Package u2) = compare (GHC.unitId u1) (GHC.unitId u2)

-- indexDependencyHieFiles gets all of the direct and transitive dependencies
-- from the HscEnv and indexes their HIE files in the HieDb.
indexDependencyHieFiles :: Recorder (WithPriority Log) -> ShakeExtras -> GHC.HscEnv -> IO ()
indexDependencyHieFiles recorder se hscEnv = do
    -- Check whether the .hls directory exists.
    dotHlsDirExists <- maybe (pure False) doesDirectoryExist mHlsDir
    -- If the .hls directory does not exits, it may have been deleted.
    -- In this case, delete the indexed source files for all
    -- dependencies that are already indexed.
    unless dotHlsDirExists deleteMissingDependencySources
    -- Index all dependency HIE files in the HieDb database.
    void $ Map.traverseWithKey indexPackageHieFiles packagesWithModules
    where
        mHlsDir :: Maybe FilePath
        mHlsDir = do
            projectDir <- resRootPath =<< lspEnv se
            pure $ projectDir </> hlsDirectory
        -- Add the deletion of dependency source files from the
        -- HieDb database to the database write queue.
        deleteMissingDependencySources :: IO ()
        deleteMissingDependencySources =
            atomically $ writeTQueue (indexQueue $ hiedbWriter se) $
                \withHieDb ->
                    withHieDb $ \db ->
                        removeDependencySrcFiles db
        -- Index all of the modules in a package (a Unit).
        indexPackageHieFiles :: Package -> [GHC.Module] -> IO ()
        indexPackageHieFiles (Package package) modules = do
            let pkgLibDir :: FilePath
                pkgLibDir = case GHC.unitLibraryDirs package of
                  []               -> ""
                  (libraryDir : _) -> libraryDir
                -- Cabal puts the HIE files for a package in the
                -- extra-compilation-artifacts directory, provided
                -- it is compiled with the -fwrite-ide-info ghc option.
                hieDir :: FilePath
                hieDir = pkgLibDir </> "extra-compilation-artifacts"
                unit :: GHC.Unit
                unit = GHC.fromUnitId $ GHC.unitId package
            -- Check if we have already indexed this package.
            moduleRows <- withHieDb se $ \db ->
                lookupPackage db unit
            case moduleRows of
                -- There are no modules from this package in the database,
                -- so go ahead and index all the modules.
                [] -> traverse_ (indexModuleHieFile hieDir) modules
                -- There are modules from this package in the database,
                -- so assume all the modules have already been indexed
                -- and do nothing.
                _  -> return ()
        indexModuleHieFile :: FilePath -> GHC.Module -> IO ()
        indexModuleHieFile hieDir m = do
            let hiePath :: NormalizedFilePath
                hiePath = toNormalizedFilePath' $
                  hieDir </> GHC.moduleNameSlashes (GHC.moduleName m) <.> "hie"
            -- Check that the module HIE file has correctly loaded. If there
            -- was some problem loading it, or if it has already been indexed
            -- (which shouldn't happen because we check whether each package
            -- has been indexed), then do nothing. Otherwise, call the
            -- indexHieFile function from Core.Compile.
            hieCheck <- checkHieFile recorder se "newHscEnvEqWithImportPaths" hiePath
            case hieCheck of
                HieFileMissing -> return ()
                HieAlreadyIndexed -> return ()
                CouldNotLoadHie _e -> return ()
                DoIndexing hash hie ->
                    -- At this point there is no source file for the HIE file,
                    -- so the HieDb.SourceFile we give is FakeFile Nothing.
                    indexHieFile se hiePath (FakeFile Nothing) hash hie
        packagesWithModules :: Map.Map Package [GHC.Module]
        packagesWithModules = Map.fromSet getModulesForPackage packages
        packages :: Set Package
        packages = Set.fromList
            $ map Package
            -- Take only the packages that are direct or transitive dependencies.
            $ filter (\unitInfo -> GHC.unitId unitInfo `Set.member` dependencyIds) allPackages
            where
                allPackages :: [GHC.UnitInfo]
                allPackages = GHC.getUnitInfo hscEnv
                dependencyIds :: Set GHC.UnitId
                dependencyIds =
                    calculateTransitiveDependencies allPackages directDependencyIds directDependencyIds
                directDependencyIds :: Set GHC.UnitId
                directDependencyIds = Set.fromList
                    $ map GHC.toUnitId
                    $ GHC.explicitUnits
                    $ GHC.unitState hscEnv

-- calculateTransitiveDependencies finds the UnitId keys in the UnitInfoMap
-- that are dependencies or transitive dependencies.
calculateTransitiveDependencies :: [GHC.UnitInfo] -> Set GHC.UnitId -> Set GHC.UnitId -> Set GHC.UnitId
calculateTransitiveDependencies allPackages allDependencies newDepencencies
    -- If there are no new dependencies, then we have found them all,
    -- so return allDependencies
    | Set.null newDepencencies = allDependencies
    -- Otherwise recursively add any dependencies of the newDepencencies
    -- that are not in allDependencies already.
    | otherwise = calculateTransitiveDependencies allPackages nextAll nextNew
    where
        nextAll :: Set GHC.UnitId
        nextAll = Set.union allDependencies nextNew
        -- Get the dependencies of the newDependencies. Then the nextNew depencencies
        -- will be the set difference of the dependencies we have so far (allDependencies),
        -- and the dependencies of the newDepencencies.
        nextNew :: Set GHC.UnitId
        nextNew = flip Set.difference allDependencies
            $ Set.unions
            $ map (Set.fromList . GHC.unitDepends)
            $ filter (\unitInfo -> GHC.unitId unitInfo `Set.member` newDepencencies) allPackages

getModulesForPackage :: Package -> [GHC.Module]
getModulesForPackage (Package package) =
    map makeModule allModules
    where
        allModules :: [GHC.ModuleName]
        allModules = map fst
            -- The modules with a Just value in the tuple
            -- are from other packages. These won't have
            -- an HIE file in this package, and should be
            -- covered by the transitive dependencies.
            ( filter (isNothing . snd)
            $ GHC.unitExposedModules package
            )
            ++ GHC.unitHiddenModules package
        makeModule :: GHC.ModuleName
                   -> GHC.Module
        makeModule = GHC.mkModule (GHC.mkUnit package)
