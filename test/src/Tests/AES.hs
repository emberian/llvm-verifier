{- |
Module           : $Header$
Description      : LLVM array tests
Stability        : provisional
Point-of-contact : jstanley
-}

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ViewPatterns     #-}

module Tests.AES (aesTests) where

import           Control.Applicative
import           Data.Maybe
import           LSS.Execution.Debugging
import           LSS.LLVMUtils
import           LSS.Simulator
import           Test.QuickCheck
import           Tests.Common
import           Text.LLVM               ((=:), Typed(..), typedValue)
import qualified Text.LLVM               as L
import           Verifier.LLVM.Backend

aesTests :: [(Args, Property)]
aesTests =
  [
    test 1 False "test-aes128-concrete" $ aes128Concrete 1
  ]
  where
    aes128Concrete v = psk v $ runAES v aes128ConcreteImpl
    runAES v         = runAllMemModelTest v (commonCB "aes128BlockEncrypt.bc")

aes128ConcreteImpl :: AllMemModelTest
aes128ConcreteImpl = do
  setSEH sanityChecks
  ptptr  <- initArr ptVals
  keyptr <- initArr keyVals
  one <- getSizeT 1
  ctptr  <- typedValue <$> alloca arrayTy one (Just 4)
  let args = map (i32p =:) [ptptr, keyptr, ctptr]
  [_, _, typedValue -> ctRawPtr] <-
    callDefine (L.Symbol "aes128BlockEncrypt") voidTy args
  Just mem <- getProgramFinalMem
  (_,ctarr) <- withSBE $ \s -> memLoad s mem (L.PtrTo arrayTy =: ctRawPtr)
  ctVals <- withSBE $ \s ->
              map (getVal s) <$> termDecomp s (replicate 4 i32) ctarr
  return (ctVals == ctChks)
  where
    getVal s v = snd $ fromJust $ asUnsignedInteger s (typedValue v)
    initArr xs = do
       arrElts <- mapM (withSBE . \x s -> termInt s 32 x) xs
       arr <- withSBE $ \sbe -> termArray sbe (L.PrimType (L.Integer 32)) arrElts
       one <- getSizeT 1
       p   <- typedValue <$> alloca arrayTy one (Just 4)
       store (arrayTy =: arr) p
       return p

    arrayTy = L.Array 4 i32
    ptVals  = [0x00112233, 0x44556677, 0x8899aabb, 0xccddeeff]
    keyVals = [0x00010203, 0x04050607, 0x08090a0b, 0x0c0d0e0f]
    ctChks  = [0x69c4e0d8, 0x6a7b0430, 0xd8cdb780, 0x70b4c55a]

--------------------------------------------------------------------------------
-- Scratch

_nowarn :: a
_nowarn = undefined main

main :: IO ()
main = runTests aesTests
