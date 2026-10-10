{-# LANGUAGE BangPatterns, MagicHash #-}
-- Used by benchmark.py with two complete, renamed Native backend modules.
module Main (main) where

import qualified NativeBefore as Before
import qualified NativeAfter as After
import Control.Exception (evaluate)
import Control.Monad (forM_, unless, when)
import qualified Data.Array as A
import Data.Array.Base (unsafeAt)
import qualified Data.Array.Unboxed as U
import Data.Bits
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Exts (Word(W#), Word#, ByteArray#)
import GHC.Num.BigNat (BigNat(BN#), bigNatFromWordList)
import GHC.Stats
import System.CPUTime
import System.Environment (getArgs)
import System.IO (hFlush, stdout)
import System.Mem (performGC)
import Text.Printf

data BigInput = BigInput !BigNat !Word !Integer
data Corpus = Words !(U.UArray Int Word) !Int | BigWords !(A.Array Int BigInput) !Int
data Version = Before | After deriving (Eq, Show)

next :: Word -> Word
next x = let a = x `xor` (x `shiftL` 13)
             b = a `xor` (a `shiftR` 7)
         in b `xor` (b `shiftL` 17)

wordPair :: String -> Word -> (Word, Word)
wordPair name x = case name of
    "random64" -> (x, next x)
    "random32" -> (x .&. 0xffffffff, next x .&. 0xffffffff)
    "random8" -> (x .&. 255, next x .&. 255)
    "small-divisor" -> (x, next x .&. 255)
    "powers-of-two" -> (x, bit (fromIntegral (next x .&. 63)))
    "shared-power" -> (x `shiftL` 20, next x `shiftL` 20)
    "equal" -> (x,x)
    "zero" -> (x,0)
    "neighbors" -> (x,x-1)
    "divisible" -> let y = x .&. 0xffffffff in (3*y,y)
    "unit" -> (x,1)
    "fibonacci" -> if testBit x 0
        then (7540113804746346429,12200160415121876738)
        else (12200160415121876738,7540113804746346429)
    _ -> error ("unknown fixture: " ++ name)

makeCorpus :: String -> Word -> Corpus
makeCorpus name seed = case lookup name [("big128",2),("big256",4),("big1024",16),("big4096",64)] of
    Nothing ->
        let pairs = map (wordPair name) (take 8192 $ iterate next seed)
        in Words (U.listArray (0,16383) (concatMap (\(a,b) -> [a,b]) pairs)) 8192
    Just size ->
        let input x =
                let limbs = take size ((x .|. bit 63) : iterate next (next x))
                    big = BN# (bigNatFromWordList limbs)
                    integer = foldl (\a w -> (a `shiftL` 64) + toInteger w) 0 limbs
                in BigInput big (next (next x) .|. 2) integer
        in BigWords (A.listArray (0,1023) (map input (take 1024 $ iterate next seed))) 1024

-- On these multiword inputs (at least two limbs, divisor >= 2), the native
-- bigNatRemWord# path is bignat_rem_word. Compose it explicitly so that the
-- installed compiler's GMP backend cannot supply the remainder operation.
bigBefore :: ByteArray# -> Word# -> Word#
bigBefore a b = Before.bignat_gcd_word_word b (Before.bignat_rem_word a b)
bigAfter :: ByteArray# -> Word# -> Word#
bigAfter a b = After.bignat_gcd_word_word b (After.bignat_rem_word a b)

runWords :: (Word# -> Word# -> Word#) -> U.UArray Int Word -> Int -> Int -> Word -> Word
runWords f values size count = go 0
  where
    go !i !acc
        | i == count = acc
        | otherwise =
            let offset = 2 * (i .&. (size-1))
                W# a = unsafeAt values offset
                W# b = unsafeAt values (offset+1)
                !value = W# (f a b)
            in go (i+1) ((acc + value) `xor` fromIntegral i)
{-# NOINLINE runWords #-}

runBig :: (ByteArray# -> Word# -> Word#) -> A.Array Int BigInput -> Int -> Int -> Word -> Word
runBig f values size count = go 0
  where
    go !i !acc
        | i == count = acc
        | otherwise = case unsafeAt values (i .&. (size-1)) of
            BigInput (BN# a) (W# b) _ ->
                let !value = W# (f a b)
                in go (i+1) ((acc + value) `xor` fromIntegral i)
{-# NOINLINE runBig #-}

run :: Version -> Corpus -> Int -> Word -> Word
run Before (Words values size) = runWords Before.bignat_gcd_word_word values size
run After (Words values size) = runWords After.bignat_gcd_word_word values size
run Before (BigWords values size) = runBig bigBefore values size
run After (BigWords values size) = runBig bigAfter values size
{-# NOINLINE run #-}

validate :: Corpus -> IO ()
validate (Words values size) = forM_ [0..size-1] $ \i -> do
    let a@(W# a') = unsafeAt values (2*i)
        b@(W# b') = unsafeAt values (2*i+1)
        expected = gcd (toInteger a) (toInteger b)
    unless (toInteger (W# (Before.bignat_gcd_word_word a' b')) == expected &&
            toInteger (W# (After.bignat_gcd_word_word a' b')) == expected) $
        error ("word result mismatch: " ++ show (a,b))
validate (BigWords values size) = forM_ [0..size-1] $ \i ->
    case unsafeAt values i of
        BigInput (BN# a) b@(W# b') integer -> do
            let expected = gcd integer (toInteger b)
            unless (toInteger (W# (bigBefore a b')) == expected &&
                    toInteger (W# (bigAfter a b')) == expected) $
                error ("multiword result mismatch: " ++ show (integer,b))

-- A changing nonce prevents sharing a previously evaluated pure computation.
-- All input construction and correctness checks happen before either clock.
measure :: Version -> Corpus -> Int -> Word -> IO (Word, Double, Double, Word, Word)
measure version corpus count nonce = do
    performGC
    s0 <- getRTSStats
    cpu0 <- getCPUTime
    wall0 <- getMonotonicTimeNSec
    value <- evaluate (run version corpus count nonce)
    wall1 <- getMonotonicTimeNSec
    cpu1 <- getCPUTime
    sTimed <- getRTSStats
    performGC
    s1 <- getRTSStats
    pure (value, fromIntegral (cpu1-cpu0) / 1000, fromIntegral (wall1-wall0),
          fromIntegral (allocated_bytes s1-allocated_bytes s0),
          fromIntegral (gcs sTimed-gcs s0))

main :: IO ()
main = do
    args <- getArgs
    let (samples,targetMs) = case args of
            [a,b] -> (read a :: Int, read b :: Double)
            _ -> error "usage: native-gcd-bench SAMPLES TARGET_MILLISECONDS +RTS -T"
    when (finiteBitSize (0::Word) /= 64) $ error "fixtures currently require 64-bit Word"
    enabled <- getRTSStatsEnabled
    unless enabled $ error "RTS statistics must be enabled with +RTS -T"
    putStrLn "case,version,sample,calls,cpu_ns_per_call,wall_ns_per_call,allocated_bytes,timed_gcs,checksum"
    let cases = ["random64","random32","random8","small-divisor","powers-of-two",
                 "shared-power","equal","zero","neighbors","divisible","unit","fibonacci",
                 "big128","big256","big1024","big4096"]
    forM_ cases $ \name -> do
        let warmup = makeCorpus name 314159265
        validate warmup
        (_,cpu,_,_,_) <- measure After warmup 200000 0
        let count = max 200000 (ceiling (200000 * targetMs * 1000000 / max 1 cpu))
        forM_ [1..samples] $ \sample -> do
            let nonce = fromIntegral sample
                corpus = makeCorpus name (next (314159265 + nonce))
                versions = if odd sample then [Before,After] else [After,Before]
            validate corpus
            forM_ versions $ \version -> do
                (value,cpuNs,wallNs,allocated,gcsTimed) <- measure version corpus count nonce
                printf "%s,%s,%d,%d,%.6f,%.6f,%d,%d,%d\n" name (show version) sample count
                    (cpuNs / fromIntegral count) (wallNs / fromIntegral count) allocated gcsTimed value
                hFlush stdout
