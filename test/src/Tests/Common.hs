{-# LANGUAGE DeriveFunctor        #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE ViewPatterns         #-}
{-# LANGUAGE ScopedTypeVariables  #-}

module Tests.Common where

import           Control.Applicative
import           Control.Arrow
import           Control.Monad
import           Control.Monad.Trans
import           Data.Int
import           Data.LLVM.TargetData
import           LSS.Execution.Codebase
import           LSS.Execution.Common
import           LSS.Execution.Utils
import           LSS.LLVMUtils
import           LSS.SBEBitBlast
import           LSS.Simulator
import           System.FilePath
import           Test.QuickCheck
import           Test.QuickCheck.Monadic
import           Text.LLVM                     ((=:))
import           Verinf.Symbolic.Common        (ConstantProjection(..), Lit, createBitEngine)
import           Verinf.Symbolic.Lit.DataTypes
import qualified Test.QuickCheck.Test          as T
import qualified Text.LLVM                     as L

data ExpectedRV a = AllPathsErr | VoidRV | RV a deriving Functor

newtype FailMsg = FailMsg String
instance Show FailMsg where show (FailMsg s) = s

padTy :: Int -> L.Type
padTy bytes = L.Array (fromIntegral bytes) i8

supportDir :: FilePath
supportDir = "test" </> "src" </> "support"

commonCB :: FilePath -> PropertyM IO Codebase
commonCB bcFile = run $ loadCodebase $ supportDir </> bcFile

assertMsg :: Bool -> String -> PropertyM IO ()
assertMsg b s = when (not b) (run $ putStrLn s) >> assert b

test :: Int -> Bool -> String -> PropertyM IO () -> (Args, Property)
test n shouldFail desc propM =
  ( stdArgs{ maxSuccess = n}
  , label desc $ handleNeg $ monadicIO $ withFailMsg propM
  )
  where
    handleNeg   = if shouldFail then expectFailure else id
    withFailMsg = if not shouldFail then forAllM (return msg) . const else id
    msg         = FailMsg $ "Test failed: '" ++ desc ++ "'"

runTests :: [(Args, Property)] -> IO ()
runTests tests = do
  results <- mapM (uncurry quickCheckWithResult) tests
  if all T.isSuccess results
    then putStrLn "All tests successful."
    else putStrLn "One or more tests failed."

chkRslt :: ConstantProjection t => L.Symbol -> ExpectedRV Integer -> Maybe t -> PropertyM IO ()
chkRslt _ (RV chk) (Just (getSVal -> Just v))
  | v == chk  = assert True
  | otherwise = assertMsg False $ "Expected " ++ show chk ++ ", got " ++ show v
chkRslt _ VoidRV Nothing
  = assert True
chkRslt _ AllPathsErr Nothing
  = assert True
chkRslt sym _ _
  = assertMsg False $ show (L.ppSymbol sym) ++ ": unexpected return value"

constTermEq :: ConstantProjection t => t -> Integer -> Bool
constTermEq (getSVal -> Just v) = (==v)
constTermEq _                   = const False

liftSim :: BitIO m l a -> Simulator sbe IO a
liftSim = SM . lift . lift . liftSBEBitBlast

type AllMemModelTest =
  (Functor sbe, ConstantProjection (SBEClosedTerm sbe))
  => Simulator sbe IO Bool

runAllMemModelTest :: Int -> PropertyM IO Codebase -> AllMemModelTest -> PropertyM IO ()
runAllMemModelTest v getCB act = do
  cb <- getCB
  assert . and =<< do
    forAllMemModels v cb $ \s m -> run $
      runSimulator cb s m liftSim defaultSEH Nothing (withVerbosity v act)

type SBEPropM a =
  forall mem.
  SBE (BitIO mem Lit) -> SBEMemory (BitIO mem Lit) -> PropertyM IO a

type MemCreator mem =
  LLVMContext -> BitEngine Lit -> MemGeom -> IO (BitBlastMemModel mem Lit, mem)

forAllMemModels :: forall a. Int -> Codebase -> SBEPropM a -> PropertyM IO [a]
forAllMemModels _v cb testProp = do
  sequence
    [ runMemTest "buddy" createBuddyMemModel
    , runMemTest "dag"   createDagMemModel
    ]
  where
    runMemTest :: String -> MemCreator mem -> PropertyM IO a
    runMemTest lbl act = do
      run $ putStrLn $ "forAllMemModels: " ++ lbl
      be         <- run createBitEngine
      (sbe, mem) <- first (sbeBitBlast lc be) <$> run (act lc be mg)
      testProp sbe mem
      where
        lc = cbLLVMCtx cb
        mg = defaultMemGeom lc

chkBinCInt32Fn :: Maybe (Gen (Int32, Int32))
               -> Int
               -> PropertyM IO Codebase
               -> L.Symbol
               -> (Int32 -> Int32 -> ExpectedRV Int32)
               -> PropertyM IO ()
chkBinCInt32Fn mgen v getCB sym chkOp = do
  forAllM (maybe arbitrary id mgen) $ \(x,y) -> do
    mapM_ (chkRslt sym (fromIntegral <$> x `chkOp` y))
      =<< runCInt32Fn v getCB sym [x, y]

chkUnaryCInt32Fn :: Maybe (Gen Int32)
                 -> Int
                 -> PropertyM IO Codebase
                 -> L.Symbol
                 -> (Int32 -> ExpectedRV Int32)
                 -> PropertyM IO ()
chkUnaryCInt32Fn mgen v getCB sym chkOp =
  forAllM (maybe arbitrary id mgen) $ \x -> do
    mapM_ (chkRslt sym (fromIntegral <$> chkOp x))
      =<< runCInt32Fn v getCB sym [x]

chkNullaryCInt32Fn :: Int -> PropertyM IO Codebase -> L.Symbol -> ExpectedRV Int32 -> PropertyM IO ()
chkNullaryCInt32Fn v getCB sym chkVal =
  mapM_ (chkRslt sym (fromIntegral <$> chkVal)) =<< runCInt32Fn v getCB sym []

runCInt32Fn :: Int -> PropertyM IO Codebase -> L.Symbol -> [Int32] -> PropertyM IO [Maybe (BitTermClosed Lit)]
runCInt32Fn v getCB sym cargs = do
  cb <- getCB
  forAllMemModels v cb $ \s m -> run $ do
    runSimulator cb s m liftSim defaultSEH Nothing $ withVerbosity v $
      callCInt32Fn sym cargs

callCInt32Fn ::
  ( LogMonad m
  , Functor m
  , MonadIO m
  , Functor sbe
  , ConstantProjection (SBEClosedTerm sbe)
  )
  => L.Symbol -> [Int32] -> Simulator sbe m (Maybe (SBEClosedTerm sbe))
callCInt32Fn sym cargs = do
  args <- forM cargs $ \x -> withSBE (\sbe -> termInt sbe 32 $ fromIntegral x)
  callDefine_ sym i32 (return $ map ((=:) i32) args)
  mrv <- getProgramReturnValue
  case mrv of
    Just rv -> Just <$> closeTermM rv
    Nothing -> return Nothing

-- possibly skip a test
psk :: Int -> PropertyM IO () -> PropertyM IO ()
psk v act = if (v > 0) then act else disabled

disabled :: PropertyM IO ()
disabled = do
  run $ putStrLn $ "Warning: Next test is DISABLED! (will report success)"

incomplete :: PropertyM IO () -> PropertyM IO ()
incomplete act = do
  run $ putStrLn $ "Warning: Next test is INCOMPLETE! (will report failure)"
  act
  assert False

runMain :: Int -> FilePath -> ExpectedRV Int32 -> PropertyM IO ()
runMain = runMain' False

runMain' :: Bool -> Int -> FilePath -> ExpectedRV Int32 -> PropertyM IO ()
runMain' quiet v bc erv = do
  psk v $ chkNullaryCInt32Fn (if quiet then 0 else v) (commonCB bc) (L.Symbol "main") erv
