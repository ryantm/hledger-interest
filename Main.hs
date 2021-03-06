module Main ( main ) where

import Hledger.Interest
import Hledger.Read
import Hledger.Query

import Control.Exception ( bracket )
import Control.Monad
import Data.List
import Data.Maybe
import Data.Ord
import Distribution.Text ( display )
import System.Console.GetOpt
import System.Environment
import System.Exit
import System.IO
import System.IO.Unsafe

import Paths_hledger_interest ( version )

data Options = Options
  { optVerbose      :: Bool
  , optShowVersion  :: Bool
  , optShowHelp     :: Bool
  , optInput        :: FilePath
  , optSourceAcc    :: String
  , optTargetAcc    :: String
  , optDCC          :: Maybe DayCountConvention
  , optRate         :: Maybe Rate
  , optBalanceToday :: Bool
  }

defaultOptions :: Options
defaultOptions = Options
  { optVerbose      = True
  , optShowVersion  = False
  , optShowHelp     = False
  , optInput        = "-"
  , optSourceAcc    = ""
  , optTargetAcc    = ""
  , optDCC          = Nothing
  , optRate         = Nothing
  , optBalanceToday = False
  }

options :: [OptDescr (Options -> Options)]
options =
 [ Option "h" ["help"]        (NoArg (\o -> o { optShowHelp = True }))                            "print this message and exit"
 , Option "V" ["version"]     (NoArg (\o -> o { optShowVersion = True }))                         "show version number and exit"
 , Option "v" ["verbose"]     (NoArg (\o -> o { optVerbose = True }))                             "echo input ledger to stdout (default)"
 , Option "q" ["quiet"]       (NoArg (\o -> o { optVerbose = False }))                            "don't echo input ledger to stdout"
 , Option ""  ["today"]       (NoArg (\o -> o { optBalanceToday = True }))                        "compute interest up until today"
 , Option "r" ["rate"]        (ReqArg (\f o -> o { optRate = Just (unsafePerformIO (parseInterestRateFile f)) }) "FILE")  "interest rate table to use"
 , Option "f" ["file"]        (ReqArg (\f o -> o { optInput = f }) "FILE")                        "input ledger file (pass '-' for stdin)"
 , Option "s" ["source"]      (ReqArg (\a o -> o { optSourceAcc = a }) "ACCOUNT")                 "interest source account"
 , Option "t" ["target"]      (ReqArg (\a o -> o { optTargetAcc = a }) "ACCOUNT")                 "interest target account"
 , Option ""  ["act"]         (NoArg (\o -> o { optDCC = Just diffAct }))                         "use 'act' day counting convention"
 , Option ""  ["30-360"]      (NoArg (\o -> o { optDCC = Just diff30_360 }))                      "use '30/360' day counting convention"
 , Option ""  ["30E-360"]     (NoArg (\o -> o { optDCC = Just diff30E_360 }))                     "use '30E/360' day counting convention"
 , Option ""  ["30E-360isda"] (NoArg (\o -> o { optDCC = Just diff30E_360isda }))                 "use '30E/360isda' day counting convention"
 , Option ""  ["annual"]      (ReqArg (\r o -> o { optRate = Just (perAnno (read r)) }) "RATE")   "annual interest rate"
 ]

usageMessage :: String
usageMessage = usageInfo header options
  where header = "Usage: hledger-interest [OPTION...] ACCOUNT"

commandLineError :: String -> IO a
commandLineError err = do hPutStrLn stderr (err ++ usageMessage)
                          exitFailure

parseOpts :: [String] -> IO (Options, [String])
parseOpts argv =
   case getOpt Permute options argv of
      (o,n,[]  ) -> return (foldl (flip id) defaultOptions o, n)
      (_,_,errs) -> commandLineError (concat errs)

main :: IO ()
main = bracket (return ()) (\() -> hFlush stdout >> hFlush stderr) $ \() -> do
  (opts, args) <- getArgs >>= parseOpts
  when (optShowVersion opts) (putStrLn (display version) >> exitSuccess)
  when (optShowHelp opts) (putStr usageMessage >> exitSuccess)
  when (null (optSourceAcc opts)) (commandLineError "required --source option is missing\n")
  when (null (optTargetAcc opts)) (commandLineError "required --target option is missing\n")
  when (isNothing (optDCC opts)) (commandLineError "no day counting convention specified\n")
  when (isNothing (optRate opts)) (commandLineError "no interest rate specified\n")
  when (length args < 1) (commandLineError "required argument ACCOUNT is missing\n")
  when (length args > 1) (commandLineError "only one interest ACCOUNT may be specified\n")
  jnl' <- readJournalFile Nothing Nothing False (optInput opts) >>= either fail return
  let [interestAcc] = args
      jnl = filterJournalTransactions (Acct interestAcc) jnl'
      ts  = sortBy (comparing tdate) (jtxns jnl)
      cfg = Config
            { interestAccount = interestAcc
            , sourceAccount = optSourceAcc opts
            , targetAccount = optTargetAcc opts
            , dayCountConvention = fromJust (optDCC opts)
            , interestRate = fromJust (optRate opts)
            }
  thisDay <- getCurrentDay
  let finalize
        | optBalanceToday opts = computeInterest thisDay
        | otherwise            = return ()
      ts' = runComputer cfg (mapM_ processTransaction ts >> finalize)
      result
        | optVerbose opts = ts' ++ ts
        | otherwise       = ts'
  mapM_ (putStr . show) (sortBy (comparing tdate) result)
