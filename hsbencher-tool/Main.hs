

module Main where

-- import Control.Monad.Reader
-- import qualified Data.Map as M
-- import Data.Time.Clock (getCurrentTime, diffUTCTime)
-- import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
-- import Data.Monoid
-- import Data.Dynamic
-- import GHC.Conc (getNumProcessors)
import System.Environment (getArgs, getEnv, getEnvironment)
import System.Console.GetOpt (getOpt', ArgOrder(Permute), OptDescr(Option), ArgDescr(..), usageInfo)
-- import System.IO (Handle, hPutStrLn, stderr, openFile, hClose, hGetContents, hIsEOF, hGetLine,
--                   IOMode(..), BufferMode(..), hSetBuffering)
-- import qualified System.IO.Streams as Strm
-- import qualified System.IO.Streams.Concurrent as Strm
-- import qualified System.IO.Streams.Process as Strm
-- import qualified System.IO.Streams.Combinators as Strm
import Data.List (isInfixOf)
import Control.Monad (unless,when)
import System.Exit (exitFailure, exitSuccess)

-- import HSBencher.Types
-- import HSBencher.Internal.Utils
-- import HSBencher.Methods.Builtin
-- import HSBencher.Internal.MeasureProcess

import HSBencher.Internal.Fusion (init,getSomething,ColData)


----------------------------------------------------------------------------------------------------

-- | Command line flags to the benchmarking executable.
data Flag = ShowHelp | ShowVersion
          | GoogleSecret String | GoogleID String
          | FTName String 
  deriving (Eq,Ord,Show,Read)

-- | Current run mode of the tool 
data Mode = Upload | Download
          deriving (Eq,Ord,Show,Read)

valid_modes :: [String]
valid_modes = [ "upload", "download" ]

-- | Command line options.
core_cli_options :: [OptDescr Flag]
core_cli_options = 
     [ Option ['h'] ["help"] (NoArg ShowHelp)
        "Show this help message and exit."
     , Option []  ["secret"] (ReqArg GoogleSecret "String") "Google Secret"
     , Option []  ["id"]     (ReqArg GoogleID "String")     "Google ID"
     , Option []  ["table"]  (ReqArg FTName "String")       "Name of FusionTable"
     ]

-- | Multiple lines of usage info help docs.
fullUsageInfo :: String
fullUsageInfo = usageInfo docs core_cli_options
 where 
  docs = "USAGE: hsbencher [mode] <flags> ...\n"++
         "\nValid modes: "++(unwords valid_modes)++
         "\n\nhsbencher-tool general options: \n"
--   ++ generalUsageStr


resolveMode :: String -> Mode
resolveMode md = 
 case filter (isInfixOf md) valid_modes of
   ["download"] -> Download
   ["upload"]   -> Upload 
   []  -> error $ "Unknown mode for hsbencher tool: "++md
   ls  -> error $ "Ambiguous mode for hsbencher tool: "++md++", matches: "++unwords ls

main :: IO ()
main = do
  args <- getArgs

  let (options,plainargs,_unrec,errs) = getOpt' Permute core_cli_options args
  
  unless (null errs) $ do
    putStrLn$ "Errors parsing command line options:"
    mapM_ (putStr . ("   "++)) errs       
    exitFailure

  when (ShowHelp `elem` options) $ do 
    putStrLn fullUsageInfo
    exitSuccess

  let (mode,rest) = 
        case plainargs of
         [] -> error $ "Command command expects the first argument to specify a mode, one of:\n" ++
                 unlines (map ("  "++) valid_modes) 
         (md:rst) -> (resolveMode md, rst)

  putStrLn ("hello world: "++show (mode,rest,options))

  ---------------------------------------------------------------------------
  -- Perform the task specified by the command line args 
  case mode of
    Download -> download options 
    Upload   -> upload options 




---------------------------------------------------------------------------
-- upload

upload :: [Flag] -> IO () 
upload = error "Upload functionality is not yet implemented"




---------------------------------------------------------------------------
-- download

download :: [Flag] -> IO ()
download = error "Download functionality is not yet implemented"
