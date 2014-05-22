{-# LANGUAGE BangPatterns, NamedFieldPuns, ScopedTypeVariables, RecordWildCards, FlexibleContexts #-}
{-# LANGUAGE CPP, OverloadedStrings, TupleSections #-}
--------------------------------------------------------------------------------
-- NOTE: This is best when compiled with "ghc -threaded"
-- However, ideally for real benchmarking runs we WANT the waitForProcess below block the whole process.
-- However^2, currently [2012.05.03] when running without threads I get errors like this:
--   benchmark.run: bench_hive.log: openFile: resource busy (file is locked)

--------------------------------------------------------------------------------

-- Disabling some stuff until we can bring it back up after the big transition [2013.05.28]:
#define DISABLED

{- | The Main module defining the HSBencher driver.
-}

module HSBencher.Internal.App
       (defaultMainWithBechmarks, defaultMainModifyConfig,
        Flag(..), all_cli_options, fullUsageInfo)
       where 

----------------------------
-- Standard library imports
import Prelude hiding (log)
import Control.Applicative    
import Control.Concurrent
import Control.Monad.Reader
import Control.Exception (evaluate, handle, SomeException, throwTo, fromException, AsyncException(ThreadKilled),try)
import Debug.Trace
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Maybe (isJust, fromJust, catMaybes, fromMaybe)
import Data.Monoid
import Data.Dynamic
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Word (Word64)
import Data.IORef
import Data.List (intercalate, sortBy, intersperse, isPrefixOf, tails, isInfixOf, delete)
import qualified Data.Set as Set
import Data.Version (versionBranch, versionTags)
import GHC.Conc (getNumProcessors)
import Numeric (showFFloat)
import System.Console.GetOpt (getOpt, getOpt', ArgOrder(Permute), OptDescr(Option), ArgDescr(..), usageInfo)
import System.Environment (getArgs, getEnv, getEnvironment, getProgName)
import System.Directory
import System.Posix.Env (setEnv)
import System.Random (randomIO)
import System.Exit
import System.FilePath (splitFileName, (</>), takeDirectory)
import System.Process (system, waitForProcess, getProcessExitCode, runInteractiveCommand, 
                       createProcess, CreateProcess(..), CmdSpec(..), StdStream(..), readProcess)
import System.IO (Handle, hPutStrLn, stderr, openFile, hClose, hGetContents, hIsEOF, hGetLine,
                  IOMode(..), BufferMode(..), hSetBuffering)
import System.IO.Unsafe (unsafePerformIO)
import qualified Data.ByteString.Char8 as B
import Text.Printf
import Text.PrettyPrint.GenericPretty (Out(doc))
-- import Text.PrettyPrint.HughesPJ (nest)
----------------------------
-- Additional libraries:

import qualified System.IO.Streams as Strm
import qualified System.IO.Streams.Concurrent as Strm
import qualified System.IO.Streams.Process as Strm
import qualified System.IO.Streams.Combinators as Strm

#ifdef USE_HYDRAPRINT
import UI.HydraPrint (hydraPrint, HydraConf(..), DeleteWinWhen(..), defaultHydraConf, hydraPrintStatic)
import Scripting.Parallel.ThreadPool (parForM)
#endif

----------------------------
-- Self imports:

import HSBencher.Types
import HSBencher.Internal.Utils
import HSBencher.Internal.Logging
import HSBencher.Internal.Config
import HSBencher.Internal.Methods
import HSBencher.Internal.MeasureProcess 
import Paths_hsbencher (version) -- Thanks, cabal!

----------------------------------------------------------------------------------------------------

hsbencherVersion :: String
hsbencherVersion = concat $ intersperse "." $ map show $ 
                   versionBranch version

-- | General usage information.
generalUsageStr :: String
generalUsageStr = unlines $
 [
   "   ",         
{-
   " Many of these options can redundantly be set either when the benchmark driver is run,",
   " or in the benchmark descriptions themselves.  E.g. --with-ghc is just for convenience.",
   "\n ENV VARS:",

-- No ENV vars currently! [2014.04.09]

   "   These environment variables control the behavior of the benchmark script:",
   " ",
   "   Command line arguments take precedence over environment variables, if both apply.",
   "   ",
-}
   " Note: This bench harness was built against hsbencher library version "++hsbencherVersion
 ]

----------------------------------------------------------------------------------------------------


gc_stats_flag :: String
gc_stats_flag = " -s " 
-- gc_stats_flag = " --machine-readable -t "

exedir :: String
exedir = "./bin"

--------------------------------------------------------------------------------

-- | Remove RTS options that are specific to -threaded mode.
pruneThreadedOpts :: [String] -> [String]
pruneThreadedOpts = filter (`notElem` ["-qa", "-qb"])

  
--------------------------------------------------------------------------------
-- Error handling
--------------------------------------------------------------------------------

path :: [FilePath] -> FilePath
path [] = ""
path ls = foldl1 (</>) ls

--------------------------------------------------------------------------------
-- Compiling Benchmarks
--------------------------------------------------------------------------------

-- | Build a single benchmark in a single configuration.
compileOne :: (Int,Int) -> Benchmark DefaultParamMeaning -> [(DefaultParamMeaning,ParamSetting)] -> BenchM BuildResult
compileOne (iterNum,totalIters) Benchmark{target=testPath,cmdargs} cconf = do
  Config{shortrun, resultsOut, stdOut, buildMethods, pathRegistry, doClean} <- ask

  let (diroffset,testRoot) = splitFileName testPath
      flags = toCompileFlags cconf
      paths = toCmdPaths     cconf
      bldid = makeBuildID testPath flags
  log  "\n--------------------------------------------------------------------------------"
  log$ "  Compiling Config "++show iterNum++" of "++show totalIters++
       ": "++testRoot++" (args \""++unwords cmdargs++"\") confID "++ show bldid
  log  "--------------------------------------------------------------------------------\n"

  matches <- lift$ 
             filterM (fmap isJust . (`filePredCheck` testPath) . canBuild) buildMethods 
  when (null matches) $ do
       logT$ "ERROR, no build method matches path: "++testPath
       logT$ "  Tried methods: "++show(map methodName buildMethods)
       logT$ "  With file preds: "
       forM buildMethods $ \ meth ->
         logT$ "    "++ show (canBuild meth)
       lift exitFailure     
  logT$ printf "Found %d methods that can handle %s: %s" 
         (length matches) testPath (show$ map methodName matches)
  let BuildMethod{methodName,clean,compile,concurrentBuild} = head matches
  when (length matches > 1) $
    logT$ " WARNING: resolving ambiguity, picking method: "++methodName

  let pathR = (M.union (M.fromList paths) pathRegistry)
  
  when doClean $ clean pathR bldid testPath

  -- Prefer the benchmark-local path definitions:
  x <- compile pathR bldid flags testPath
  logT$ "Compile finished, result: "++ show x
  return x
  

--------------------------------------------------------------------------------
-- Running Benchmarks
--------------------------------------------------------------------------------

-- If the benchmark has already been compiled doCompile=False can be
-- used to skip straight to the execution.
runOne :: (Int,Int) -> BuildID -> BuildResult -> Benchmark DefaultParamMeaning -> [(DefaultParamMeaning,ParamSetting)] -> BenchM ()
runOne (iterNum, totalIters) _bldid bldres
       Benchmark{target=testPath, cmdargs=args_, progname, benchTimeOut}
       runconfig = do       
  let numthreads = foldl (\ acc (x,_) ->
                           case x of
                             Threads n -> n
                             _         -> acc)
                   0 runconfig
      sched      = foldl (\ acc (x,_) ->
                           case x of
                             Variant s -> s
                             _         -> acc)
                   "none" runconfig
      
  let runFlags = toRunFlags runconfig
      envVars  = toEnvVars  runconfig
  conf@Config{ runTimeOut, trials, shortrun, argsBeforeFlags, harvesters } <- ask 
  -- maxthreads, runID, skipTo, ciBuildID, hostname, startTime, pathRegistry, 
  -- doClean, keepgoing, benchlist, benchsetName, benchversion, resultsFile, logFile, gitInfo,
  -- buildMethods, logOut, resultsOut, stdOut, envs, plugInConfs 

  ----------------------------------------
  -- (1) Gather contextual information
  ----------------------------------------  
  let args = if shortrun then shortArgs args_ else args_
      fullargs = if argsBeforeFlags 
                 then args ++ runFlags
                 else runFlags ++ args
      testRoot = fetchBaseName testPath
  log$ "\n--------------------------------------------------------------------------------"
  log$ "  Running Config "++show iterNum++" of "++show totalIters ++": "++testPath
--       "  threads "++show numthreads++" (Env="++show envVars++")"
  log$ nest 3 $ show$ doc$ map snd runconfig
  log$ "--------------------------------------------------------------------------------\n"
  pwd <- lift$ getCurrentDirectory
  logT$ "(In directory "++ pwd ++")"

  logT$ "Next run 'who', reporting users other than the current user.  This may help with detectivework."
--  whos <- lift$ run "who | awk '{ print $1 }' | grep -v $USER"
  whos <- lift$ runLines$ "who"
  let whos' = map ((\ (h:_)->h) . words) whos
  user <- lift$ getEnv "USER"
  logT$ "Who_Output: "++ unwords (filter (/= user) whos')

  -- If numthreads == 0, that indicates a serial run:

  ----------------------------------------
  -- (2) Now execute N trials:
  ----------------------------------------
  -- (One option woud be dynamic feedback where if the first one
  -- takes a long time we don't bother doing more trials.)
  nruns <- forM [1..trials] $ \ i -> do 
    log$ printf "  Running trial %d of %d" i trials
    log "  ------------------------"
    let doMeasure cmddescr = do
          SubProcess {wait,process_out,process_err} <-
            lift$ measureProcess harvesters cmddescr
          err2 <- lift$ Strm.map (B.append " [stderr] ") process_err
          both <- lift$ Strm.concurrentMerge [process_out, err2]
          mv <- echoStream (not shortrun) both
          lift$ takeMVar mv
          x <- lift wait
          return x
    case bldres of
      StandAloneBinary binpath -> do
        -- NOTE: For now allowing rts args to include things like "+RTS -RTS", i.e. multiple tokens:
        let command = binpath++" "++unwords fullargs 
        logT$ " Executing command: " ++ command
        let timeout = if benchTimeOut == Nothing
                      then runTimeOut
                      else benchTimeOut
        case timeout of
          Just t  -> logT$ " Setting timeout: " ++ show t
          Nothing -> return ()
        doMeasure CommandDescr{ command=ShellCommand command, envVars, timeout, workingDir=Nothing }
      RunInPlace fn -> do
--        logT$ " Executing in-place benchmark run."
        let cmd = fn fullargs envVars
        logT$ " Generated in-place run command: "++show cmd
        doMeasure cmd

  ------------------------------------------
  -- (3) Produce output to the right places:
  ------------------------------------------
  let pads n s = take (max 1 (n - length s)) $ repeat ' '
      padl n x = pads n x ++ x 
      padr n x = x ++ pads n x
  let thename = case progname of
                  Just s  -> s
                  Nothing -> testRoot
  (_t1,_t2,_t3,_p1,_p2,_p3) <-
    if all isError nruns then do
      log $ "\n >>> MIN/MEDIAN/MAX (TIME,PROD) -- got only ERRORS: " ++show nruns
      logOn [ResultsFile]$ 
        printf "# %s %s %s %s %s" (padr 35 thename) (padr 20$ intercalate "_" args)
                                  (padr 8$ sched) (padr 3$ show numthreads) (" ALL_ERRORS"::String)
      return ("","","","","","")
    else do
      let goodruns = filter (not . isError) nruns
      -- Extract the min, median, and max:
          sorted = sortBy (\ a b -> compare (gettime a) (gettime b)) goodruns
          minR = head sorted
          maxR = last sorted
          medianR = sorted !! (length sorted `quot` 2)

      let ts@[t1,t2,t3]    = map (\x -> showFFloat Nothing x "")
                             [gettime minR, gettime medianR, gettime maxR]
          prods@[p1,p2,p3] = map mshow [getprod minR, getprod medianR, getprod maxR]
          mshow Nothing  = "0"
          mshow (Just x) = showFFloat (Just 2) x "" 

          -- These are really (time,prod) tuples, but a flat list of
          -- scalars is simpler and readable by gnuplot:
          formatted = (padl 15$ unwords $ ts)
                      ++"   "++ unwords prods -- prods may be empty!

      log $ "\n >>> MIN/MEDIAN/MAX (TIME,PROD) " ++ formatted

      logOn [ResultsFile]$ 
        printf "%s %s %s %s %s" (padr 35 thename) (padr 20$ intercalate "_" args)
                                (padr 8$ sched) (padr 3$ show numthreads) formatted

      -- These should be either all Nothing or all Just:
      let jittimes0 = map getjittime goodruns
          misses = length (filter (==Nothing) jittimes0)
      jittimes <- if misses == length goodruns
                  then return ""
                  else if misses == 0
                       then return $ unwords (map (show . fromJust) jittimes0)
                       else do log $ "WARNING: got JITTIME for some runs: "++show jittimes0
                               log "  Zeroing those that did not report."
                               return $ unwords (map (show . fromMaybe 0) jittimes0)
      let result =
            emptyBenchmarkResult
            { _PROGNAME = case progname of
                           Just s  -> s
                           Nothing -> testRoot
            , _VARIANT  = sched
            , _ARGS     = args
            , _THREADS  = numthreads
            , _MINTIME    =  gettime minR
            , _MEDIANTIME =  gettime medianR
            , _MAXTIME    =  gettime maxR
            , _MINTIME_PRODUCTIVITY    = getprod minR
            , _MEDIANTIME_PRODUCTIVITY = getprod medianR
            , _MEDIANTIME_ALLOCRATE    = getallocrate medianR
            , _MEDIANTIME_MEMFOOTPRINT = getmemfootprint medianR
            , _MAXTIME_PRODUCTIVITY    = getprod maxR
            , _RUNTIME_FLAGS = unwords runFlags
            , _ALLTIMES      =  unwords$ map (show . gettime)    goodruns
            , _ALLJITTIMES   =  jittimes
            , _TRIALS        =  trials

                                -- Should the user specify how the
                                -- results over many goodruns are reduced ?
                                -- I think so. 
            , _CUSTOM        = custom (head goodruns) -- experimenting 
            }
      result' <- liftIO$ augmentResultWithConfig conf result

      -- Upload results to plugin backends:
      conf2@Config{ plugIns } <- ask 
      forM_ plugIns $ \ (SomePlugin p) -> do 

        --JS: May 21 2014, added try and case on result. 
        result <- liftIO$ try (plugUploadRow p conf2 result') :: ReaderT Config IO (Either SomeException ()) 
        case result of
          Left _ -> logT$"plugUploadRow:Failed"
          Right () -> return ()
        return ()

      return (t1,t2,t3,p1,p2,p3)
      
  return ()     


--------------------------------------------------------------------------------


-- | Write the results header out stdout and to disk.
printBenchrunHeader :: BenchM ()
printBenchrunHeader = do
  Config{trials, maxthreads, pathRegistry, 
         logOut, resultsOut, stdOut, benchversion, shortrun, gitInfo=(branch,revision,depth) } <- ask
  liftIO $ do   
--    let (benchfile, ver) = benchversion
    let ls :: [IO String]
        ls = [ e$ "# TestName Variant NumThreads   MinTime MedianTime MaxTime  Productivity1 Productivity2 Productivity3"
             , e$ "#    "        
             , e$ "# `date`"
             , e$ "# `uname -a`" 
             , e$ "# Ran by: `whoami` " 
             , e$ "# Determined machine to have "++show maxthreads++" hardware threads."
             , e$ "# "                                                                
             , e$ "# Running each test for "++show trials++" trial(s)."
--             , e$ "# Benchmarks_File: " ++ benchfile
--             , e$ "# Benchmarks_Variant: " ++ if shortrun then "SHORTRUN" else whichVariant benchfile
--             , e$ "# Benchmarks_Version: " ++ show ver
             , e$ "# Git_Branch: " ++ branch
             , e$ "# Git_Hash: "   ++ revision
             , e$ "# Git_Depth: "  ++ show depth
             -- , e$ "# Using the following settings from environment variables:" 
             -- , e$ "#  ENV BENCHLIST=$BENCHLIST"
             -- , e$ "#  ENV THREADS=   $THREADS"
             -- , e$ "#  ENV TRIALS=    $TRIALS"
             -- , e$ "#  ENV SHORTRUN=  $SHORTRUN"
             -- , e$ "#  ENV KEEPGOING= $KEEPGOING"
             -- , e$ "#  ENV GHC=       $GHC"
             -- , e$ "#  ENV GHC_FLAGS= $GHC_FLAGS"
             -- , e$ "#  ENV GHC_RTS=   $GHC_RTS"
             -- , e$ "#  ENV ENVS=      $ENVS"
             , e$ "#  Path registry: "++show pathRegistry
             ]
    ls' <- sequence ls
    forM_ ls' $ \line -> do
      Strm.write (Just$ B.pack line) resultsOut
      Strm.write (Just$ B.pack line) logOut 
      Strm.write (Just$ B.pack line) stdOut
    return ()

 where 
   -- This is a hack for shell expanding inside a string:
   e :: String -> IO String
   e s =
     runSL ("echo \""++s++"\"")
     -- readCommand ("echo \""++s++"\"")
--     readProcess "echo" ["\""++s++"\""] ""


----------------------------------------------------------------------------------------------------
-- Main Script
----------------------------------------------------------------------------------------------------


-- | TODO: Eventually this will make sense when all config can be read from the environment, args, files.
defaultMain :: IO ()
defaultMain = do
  --      benchF = get "BENCHLIST" "benchlist.txt"
--  putStrLn$ hsbencher_tag ++ " Reading benchmark list from file: "
  error "FINISHME: defaultMain requires reading benchmark list from a file.  Implement it!"
--  defaultMainWithBechmarks undefined

-- | In this version, user provides a list of benchmarks to run, explicitly.
defaultMainWithBechmarks :: [Benchmark DefaultParamMeaning] -> IO ()
defaultMainWithBechmarks benches = do
  defaultMainModifyConfig (\ conf -> conf{ benchlist=benches })

-- | Multiple lines of usage info help docs.
fullUsageInfo :: String
fullUsageInfo = 
    "\nUSAGE: naked command line arguments are patterns that select the benchmarks to run.\n"++
    (concat (map (uncurry usageInfo) all_cli_options)) ++
    generalUsageStr

    
-- | Remove a plugin from the configuration based on its plugName
removePlugin :: Plugin p => p -> Config -> Config 
removePlugin p cfg = 
  cfg { plugIns = filter byNom  (plugIns cfg)}
  where
    byNom (SomePlugin p1) =  plugName p1 /= plugName p

-- | An even more flexible version allows the user to install a hook which modifies
-- the configuration just before bencharking begins.  All trawling of the execution
-- environment (command line args, environment variables) happens BEFORE the user
-- sees the configuration.
--
-- This function doesn't take a benchmark list separately, because that simply
-- corresponds to the 'benchlist' field of the output 'Config'.
defaultMainModifyConfig :: (Config -> Config) -> IO ()
defaultMainModifyConfig modConfig = do    
  id <- myThreadId
  writeIORef main_threadid id
  my_name  <- getProgName
  cli_args <- getArgs

  let (options,plainargs,_unrec,errs) = getOpt' Permute (concat$ map snd all_cli_options) cli_args

  -- This ugly method avoids needing an Eq instance:
  let recomp       = null [ () | NoRecomp <- options]
      showHelp      = not$ null [ () | ShowHelp <- options]
      gotVersion   = not$ null [ () | ShowVersion <- options]
      cabalAllowed = not$ null [ () | NoCabal <- options]
      parBench     = not$ null [ () | ParBench <- options]

  when gotVersion  $ do
    putStrLn$ "hsbencher version "++ hsbencherVersion
      -- (unwords$ versionTags version)
    exitSuccess 

  let printHelp :: [OptDescr ()] -> IO ()
      printHelp opts = 
        error "FINISHME"

  putStrLn$ "\n"++hsbencher_tag++"Harvesting environment data to build Config."
  conf0 <- getConfig options []
  -- The list of benchmarks can optionally be narrowed to match any of the given patterns.
  let conf1 = modConfig conf0
  -- The phasing here is rather funny.  We need to get the initial config to know
  -- WHICH plugins are active.  And then their individual per-plugin configs need to
  -- be computed and added to the global config.
  let allplugs = plugIns conf1


  when (not (null errs) || showHelp) $ do
    unless showHelp $ putStrLn$ "Errors parsing command line options:"
    mapM_ (putStr . ("   "++)) errs       
    putStrLn$ "\nUSAGE: [set ENV VARS] "++my_name++" [CMDLN OPTS]"
    putStrLn$ "\nNote: \"CMDLN OPTS\" includes patterns that select which benchmarks"
    putStrLn$ "     to run, based on name."

    mapM putStr (map (uncurry usageInfo) all_cli_options)
    putStrLn ""
    forM_ allplugs $ \ (SomePlugin p) -> do  
      putStrLn $ ((uncurry usageInfo) (plugCmdOpts p))
    putStrLn$ generalUsageStr
    if showHelp then exitSuccess else exitFailure


  -- Hmm, not really a strong reason to *combine* the options lists, rather we do
  -- them one at a time:
  let pconfs = [ (plugName p, SomePluginConf p pconf)
               | (SomePlugin p) <- (plugIns conf1)
               , let (_pusage,popts) = plugCmdOpts p
               , let (o2,_,_,_) = getOpt' Permute popts cli_args 
               , let pconf = foldFlags p o2 (defaultPlugConf p)
               ]

  let conf2 = conf1 { plugInConfs = M.fromList pconfs }
  -- Combine all plugins command line options, and reparse the command line.

  putStrLn$ hsbencher_tag++(show$ length allplugs)++" plugins configured, now initializing them."

  -- TODO/FIXME: CATCH ERRORS... should remove the plugin from the list if it errors on init.
  -- JS attempted fix
  conf_final <- foldM (\ cfg (SomePlugin p) ->
                        do result <- try (plugInitialize p cfg) :: IO (Either SomeException Config) 
                           case result of
                             Left _ ->
                               return $ removePlugin p cfg
                               -- cannot log here, only "chatter". 
                             Right c -> return c 
                        ) conf2 allplugs

  putStrLn$ hsbencher_tag++" plugin init complete."

  -------------------------------------------------------------------
  -- Next prune the list of benchmarks to those selected by the user:
  let cutlist = case plainargs of
                 [] -> benchlist conf_final
                 patterns -> filter (\ Benchmark{target,cmdargs,progname} ->
                                      any (\pat ->
                                            isInfixOf pat target ||
                                            isInfixOf pat (fromMaybe "" progname) ||
                                            any (isInfixOf pat) cmdargs
                                          )
                                          patterns)
                                    (benchlist conf_final)
  let conf2@Config{envs,benchlist,stdOut} = conf_final{benchlist=cutlist}

  hasMakefile <- doesFileExist "Makefile"
  cabalFile   <- runLines "ls *.cabal"
  let hasCabalFile = (cabalFile /= []) && cabalAllowed
  rootDir <- getCurrentDirectory  
  runReaderT 
    (do
        unless (null plainargs) $ do
          let len = (length cutlist)
          logT$"There were "++show len++" benchmarks matching patterns: "++show plainargs
          when (len == 0) $ do 
            error$ "Expected at least one pattern to match!.  All benchmarks: \n"++
                   (case conf_final of 
                     Config{benchlist=ls} -> 
                       (unlines  [ (target ++ (unwords cmdargs))
                               | Benchmark{cmdargs,target} <- ls
                               ]))
        
        logT$"Beginning benchmarking, root directory: "++rootDir
        let globalBinDir = rootDir </> "bin"
        when recomp $ do
          logT$"Clearing any preexisting files in ./bin/"
          lift$ do
            -- runSimple "rm -f ./bin/*"
            -- Yes... it's posix dependent.  But right now I don't see a good way to
            -- delete the contents a dir without (1) following symlinks or (2) assuming
            -- either the unix package or unix shell support (rm).
            --- Ok, what the heck, deleting recursively:
            dde <- doesDirectoryExist globalBinDir
            when dde $ removeDirectoryRecursive globalBinDir
        lift$ createDirectoryIfMissing True globalBinDir 
     
	logT "Writing header for result data file:"
	printBenchrunHeader
     
        unless recomp $ log "[!!!] Skipping benchmark recompilation!"

        let
            benches' = map (\ b -> b { configs= compileOptsOnly (configs b) })
                       benchlist
            cccfgs = map (enumerateBenchSpace . configs) benches' -- compile configs
            cclengths = map length cccfgs
            totalcomps = sum cclengths
            
        log$ "\n--------------------------------------------------------------------------------"
        logT$ "Running all benchmarks for all settings ..."
        logT$ "Compiling: "++show totalcomps++" total configurations of "++ show (length benchlist)++" benchmarks"
        let indent n str = unlines $ map (replicate n ' ' ++) $ lines str
            printloop _ [] = return ()
            printloop mp (Benchmark{target,cmdargs,configs} :tl) = do
              log$ " * Benchmark/args: "++target++" "++show cmdargs
              case M.lookup configs mp of
                Nothing -> log$ indent 4$ show$ doc configs
                Just trg0 -> log$ "   ...same config space as "++show trg0
              printloop (M.insertWith (\ _ x -> x) configs target mp) tl
--        log$ "Benchmarks/compile options: "++show (doc benches')              
        printloop M.empty benchlist
        log$ "--------------------------------------------------------------------------------"

        if parBench then do
            unless rtsSupportsBoundThreads $ error (my_name++" was NOT compiled with -threaded.  Can't do --par.")
     {-            
        --------------------------------------------------------------------------------
        -- Parallel version:
            numProcs <- liftIO getNumProcessors
            lift$ putStrLn$ "[!!!] Compiling in Parallel, numProcessors="++show numProcs++" ... "
               
            when recomp $ liftIO$ do 
              when hasCabalFile (error "Currently, cabalized build does not support parallelism!")
            
              (strms,barrier) <- parForM numProcs (zip [1..] pruned) $ \ outStrm (confnum,bench) -> do
                 outStrm' <- Strm.unlines outStrm
                 let conf' = conf { stdOut = outStrm' } 
                 runReaderT (compileOne bench (confnum,length pruned)) conf'
                 return ()
              catParallelOutput strms stdOut
              res <- barrier
              return ()

            Config{shortrun,doFusionUpload} <- ask
	    if shortrun && not doFusionUpload then liftIO$ do
               putStrLn$ "[!!!] Running in Parallel..."              
               (strms,barrier) <- parForM numProcs (zip [1..] pruned) $ \ outStrm (confnum,bench) -> do
                  outStrm' <- Strm.unlines outStrm
                  let conf' = conf { stdOut = outStrm' }
                  runReaderT (runOne bench (confnum,totalcomps)) conf'
               catParallelOutput strms stdOut
               _ <- barrier
               return ()
	     else do
               -- Non-shortrun's NEVER run multiple benchmarks at once:
	       forM_ (zip [1..] allruns) $ \ (confnum,bench) -> 
		    runOne bench (confnum,totalcomps)
               return ()
-}
        else do
        --------------------------------------------------------------------------------
        -- Serial version:
          -- TODO: make this a foldlM:
          let allruns = map (enumerateBenchSpace . configs) benchlist
              allrunsLens = map length allruns
              totalruns = sum allrunsLens
          let 
              -- Here we lazily compile benchmarks as they become required by run configurations.
              runloop :: Int 
                      -> M.Map BuildID (Int, Maybe BuildResult)
                      -> M.Map FilePath BuildID -- (S.Set ParamSetting)
                      -> [(Benchmark DefaultParamMeaning, [(DefaultParamMeaning,ParamSetting)])]
                      -> BenchM ()
              runloop _ _ _ [] = return ()
              runloop !iter !board !lastConfigured (nextrun:rest) = do
                -- lastConfigured keeps track of what configuration was last built in
                -- a directory that is used for `RunInPlace` builds.
                let (bench,params) = nextrun
                    ccflags = toCompileFlags params
                    bid = makeBuildID (target bench) ccflags
                case M.lookup bid board of 
                  Nothing -> error$ "HSBencher: Internal error: Cannot find entry in map for build ID: "++show bid
                  Just (ccnum, Nothing) -> do 
                    res  <- compileOne (ccnum,totalcomps) bench params                    
                    let board' = M.insert bid (ccnum, Just res) board
                        lastC' = M.insert (target bench) bid lastConfigured

                    -- runloop iter board' (nextrun:rest)
                    runOne (iter,totalruns) bid res bench params
                    runloop (iter+1) board' lastC' rest

                  Just (ccnum, Just bldres) -> 
                    let proceed = do runOne (iter,totalruns) bid bldres bench params
                                     runloop (iter+1) board lastConfigured rest 
                    in
                    case bldres of 
                      StandAloneBinary _ -> proceed
                      RunInPlace _ -> 
                        -- Here we know that some previous compile with the same BuildID inserted this here.
                        -- But the relevant question is whether some other config has stomped on it in the meantime.
                        case M.lookup (target bench) lastConfigured of 
                          Nothing -> error$"HSBencher: Internal error, RunInPlace in the board but not lastConfigured!: "
                                       ++(target bench)++ " build id "++show bid
                          Just bid2 ->
                           if bid == bid2 
                           then do logT$ "Skipping rebuild of in-place benchmark: "++bid
                                   proceed 
                           else runloop iter (M.insert bid (ccnum,Nothing) board) lastConfigured (nextrun:rest)

              -- Keeps track of what's compiled.
              initBoard _ [] acc = acc 
              initBoard !iter ((bench,params):rest) acc = 
                let bid = makeBuildID (target bench) $ toCompileFlags params 
                    base = fetchBaseName (target bench)
                    dfltdest = globalBinDir </> base ++"_"++bid in
                case M.lookup bid acc of
                  Just _  -> initBoard iter rest acc
                  Nothing -> 
                    let elm = if recomp 
                              then (iter, Nothing)
                              else (iter, Just (StandAloneBinary dfltdest))
                    in
                    initBoard (iter+1) rest (M.insert bid elm acc)

              zippedruns = (concat$ zipWith (\ b cfs -> map (b,) cfs) benchlist allruns)

          unless recomp $ logT$ "Recompilation disabled, assuming standalone binaries are in the expected places!"
          let startBoard = initBoard 1 zippedruns M.empty
          Config{skipTo} <- ask
          case skipTo of 
            Nothing -> runloop 1 startBoard M.empty zippedruns
            Just ix -> do logT$" !!! WARNING: SKIPPING AHEAD in configuration space; jumping to: "++show ix
                          runloop ix startBoard M.empty (drop (ix-1) zippedruns)

{-
        do Config{logOut, resultsOut, stdOut} <- ask
           liftIO$ Strm.write Nothing logOut 
           liftIO$ Strm.write Nothing resultsOut 
-}
        log$ "\n--------------------------------------------------------------------------------"
        log "  Finished with all test configurations."
        log$ "--------------------------------------------------------------------------------"
	liftIO$ exitSuccess
    )
    conf2


-- Several different options for how to display output in parallel:
catParallelOutput :: [Strm.InputStream B.ByteString] -> Strm.OutputStream B.ByteString -> IO ()
catParallelOutput strms stdOut = do 
 case 4 of
#ifdef USE_HYDRAPRINT   
   -- First option is to create N window panes immediately.
   1 -> do
           hydraPrintStatic defaultHydraConf (zip (map show [1..]) strms)
   2 -> do
           srcs <- Strm.fromList (zip (map show [1..]) strms)
           hydraPrint defaultHydraConf{deleteWhen=Never} srcs
#endif
   -- This version interleaves their output lines (ugly):
   3 -> do 
           strms2 <- mapM Strm.lines strms
           interleaved <- Strm.concurrentMerge strms2
           Strm.connect interleaved stdOut
   -- This version serializes the output one worker at a time:           
   4 -> do
           strms2 <- mapM Strm.lines strms
           merged <- Strm.concatInputStreams strms2
           -- Strm.connect (head strms) stdOut
           Strm.connect merged stdOut


----------------------------------------------------------------------------------------------------
-- *                                 GENERIC HELPER ROUTINES                                      
----------------------------------------------------------------------------------------------------

-- These should go in another module.......

didComplete :: RunResult -> Bool
didComplete RunCompleted{} = True
didComplete _              = False

isError :: RunResult -> Bool
isError ExitError{} = True
isError _           = False

getprod :: RunResult -> Maybe Double
getprod RunCompleted{productivity} = productivity
getprod RunTimeOut{}               = Nothing
getprod x                          = error$"Cannot get productivity from: "++show x

getallocrate :: RunResult -> Maybe Word64
getallocrate RunCompleted{allocRate} = allocRate
getallocrate _                       = Nothing

getmemfootprint :: RunResult -> Maybe Word64
getmemfootprint RunCompleted{memFootprint} = memFootprint
getmemfootprint _                          = Nothing

gettime :: RunResult -> Double
gettime RunCompleted{realtime} = realtime
gettime RunTimeOut{}           = posInf
gettime x                      = error$"Cannot get realtime from: "++show x

getjittime :: RunResult -> Maybe Double
getjittime RunCompleted{jittime}  = jittime
getjittime _                      = Nothing

posInf :: Double
posInf = 1/0


-- Compute a cut-down version of a benchmark's args list that will do
-- a short (quick) run.  The way this works is that benchmarks are
-- expected to run and do something quick if they are invoked with no
-- arguments.  (A proper benchmarking run, therefore, requires larger
-- numeric arguments be supplied.)
-- 
shortArgs :: [String] -> [String]
shortArgs _ls = []

-- shortArgs [] = []
-- DISABLING:
-- HOWEVER: there's a further hack here which is that leading
-- non-numeric arguments are considered qualitative (e.g. "monad" vs
-- "sparks") rather than quantitative and are not pruned by this
-- function.
-- shortArgs (h:tl) | isNumber h = []
-- 		 | otherwise  = h : shortArgs tl

----------------------------------------------------------------------------------------------------

nest :: Int -> String -> String
nest n str = remlastNewline $ unlines $ 
             map (replicate n ' ' ++) $
             lines str
 where
   remlastNewline str =
     case reverse str of
       '\n':rest -> reverse rest
       _         -> str