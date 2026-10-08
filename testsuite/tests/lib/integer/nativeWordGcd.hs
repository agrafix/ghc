{-# LANGUAGE MagicHash #-}
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Bits
import GHC.Exts (Word(W#))
import GHC.Internal.Bignum.Backend.Native (bignat_gcd_word_word)

nativeGcd :: Word -> Word -> Word
nativeGcd (W# a) (W# b) = W# (bignat_gcd_word_word a b)

check :: (Word, Word) -> IO ()
check (a,b) = unless (actual == expected) $
    error (show (a,b,actual,expected))
  where
    actual = nativeGcd a b
    -- An independent Euclidean reference; do not call the backend under test
    -- indirectly through the public gcd implementation.
    expected = euclid a b
    euclid x 0 = x
    euclid x y = euclid y (x `rem` y)

next :: Word -> Word
next x = let a = x `xor` (x `shiftL` 13)
             b = a `xor` (a `shiftR` 7)
         in b `xor` (b `shiftL` 17)

main :: IO ()
main = do
    forM_ [(a,b) | a <- [0..255], b <- [0..255]] check
    let edges = 0 : maxBound :
          [x | k <- [0..finiteBitSize (0::Word)-1], x <- [bit k-1,bit k,bit k+1]]
    forM_ [(a,b) | a <- edges, b <- edges] check
    forM_ (take 100000 $ iterate next 314159265) $ \x -> do
        check (x,next x)
        check (x,x-1)
        check (x,1)
        check (x `shiftL` 7, next x `shiftL` 7)
    putStrLn "OK"
