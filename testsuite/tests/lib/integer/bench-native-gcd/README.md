# Native word GCD: change and benchmark report

The patch makes random 32-bit and 64-bit word GCDs **about 1.25 times as
fast** on an Apple M4 Max, or about 20% less CPU time per call. Computing
the GCD of a 128-bit or 256-bit number with one machine word improves by
about 1.22x and 1.15x respectively. The measurements show no clear gain for
the 1,024-bit and 4,096-bit cases.

There are small regressions: `gcd(x, 0)` takes 1.54 -> 1.66 ns and
`gcd(x, x-1)` takes 2.52 -> 3.05 ns. Equal operands, exact divisibility and
unit operands show no clear change. This is evidence for a useful native
backend optimization with tradeoffs; application-level gains still need
measurement. The GMP backend is unaffected by this patch.

The measurements were collected on **2026-10-09**, using **GHC 9.12.2,
`-O2`, the native code generator, macOS 15.6 and 64-bit ARM**. The compiler
was a prebuilt binary distribution: no GHC compiler rebuild was needed.

The source comparison is pinned to these commits:

| Version | Commit | Behavior |
| --- | --- | --- |
| Before | [65bcf9e](https://github.com/agrafix/ghc/commit/65bcf9e9116c3a8170d3a7e568f2a35f4bd7c3b8) | Euclidean word GCD using repeated remainders |
| After | [daf277c](https://github.com/agrafix/ghc/commit/daf277c904b19b371cad15ef61e1cf98fa7afd7b) | One remainder step followed by binary GCD |

The changed routine is `bignat_gcd_word_word` in
[Native.hs](../../../../../libraries/ghc-internal/src/GHC/Internal/Bignum/Backend/Native.hs).
It computes the greatest common divisor of two unsigned machine words.
The new implementation first handles zero operands, then takes one
remainder using the smaller operand as the divisor. This quickly reduces
very unequal inputs and finishes immediately when one divides the other.
It then removes powers of two and repeatedly subtracts the smaller odd
operand from the larger, stripping trailing zero bits after each step.
A comparison-derived mask selects the smaller operand and the absolute
difference without a branch on their ordering inside that loop.

The correctness argument follows the usual GCD identities. A remainder
step preserves the GCD. Removing powers of two from both operands preserves
their odd common factors; the minimum of the two trailing-zero counts is
saved and restored at the end. For unequal odd operands, subtraction
preserves the GCD and produces a nonzero even difference. Removing its
powers of two is safe because the other operand is odd. Each iteration
reduces the largest operand, so the loop terminates. Zero and equality
checks ensure that trailing-zero counts used by unchecked shifts are
always less than the word size. The mask calculation uses unsigned word
arithmetic to obtain the absolute difference even when subtraction wraps.

The complete results are below. Times are median CPU nanoseconds per call,
including the benchmark loop and checksum work. **Speedup greater than 1
means faster; less than 1 means slower.** Speedup is the median of the 15
paired before/after ratios, so it can differ from dividing the two time
columns. The final column is a 95% bootstrap interval for that paired
median, calculated with 10,000 resamples.

| Fixture | Before (ns) | After (ns) | Speedup | 95% interval |
| --- | ---: | ---: | ---: | ---: |
| `random64` | 140.38 | 112.80 | 1.246x | 1.238–1.254 |
| `random32` | 70.08 | 56.18 | 1.245x | 1.237–1.253 |
| `random8` | 10.63 | 5.89 | 1.896x | 1.740–1.972 |
| `small-divisor` | 11.98 | 6.40 | 1.820x | 1.668–1.954 |
| `powers-of-two` | 70.77 | 5.59 | 12.657x | 12.371–13.104 |
| `shared-power` | 101.79 | 77.62 | 1.310x | 1.309–1.315 |
| `equal` | 1.94 | 1.93 | 1.005x | 0.991–1.012 |
| `zero` | 1.54 | 1.66 | 0.925x | 0.919–0.934 |
| `neighbors` | 2.52 | 3.05 | 0.823x | 0.820–0.828 |
| `divisible` | 1.94 | 1.92 | 1.008x | 0.953–1.020 |
| `unit` | 1.93 | 1.94 | 0.992x | 0.898–1.004 |
| `fibonacci` | 328.36 | 84.49 | 3.877x | 3.645–3.882 |
| `big128` | 161.07 | 131.86 | 1.219x | 1.215–1.227 |
| `big256` | 174.49 | 151.78 | 1.151x | 1.139–1.160 |
| `big1024` | 271.50 | 268.36 | 1.025x | 0.987–1.036 |
| `big4096` | 844.80 | 819.27 | 1.038x | 0.998–1.050 |

The `big1024` and `big4096` intervals include 1.0, so their point estimates
do not establish a gain. The decreasing benefit is consistent with the
unchanged multiword remainder operation taking a larger share of the work.
The especially large power-of-two and Fibonacci gains apply to those
specific input patterns. The zero and neighboring-input regressions are
about 8% and 21% more time, respectively, despite their small absolute cost.

Fixture names map to these inputs; [Main.hs](Main.hs) contains the exact
deterministic generators:

| Fixtures | Inputs |
| --- | --- |
| `random64`, `random32`, `random8` | Consecutive values from a xorshift generator, limited to the stated number of bits |
| `small-divisor` | A full word and a second operand in 0–255, including zero |
| `powers-of-two` | A full word and a power of two from 2^0 through 2^63 |
| `shared-power` | Two generated words shifted left by 20 bits within a 64-bit word |
| `equal`, `zero`, `neighbors`, `unit` | `(x,x)`, `(x,0)`, `(x,x-1)`, `(x,1)` |
| `divisible` | `(3*y,y)`, where `y` is limited to 32 bits |
| `fibonacci` | The consecutive values 7540113804746346429 and 12200160415121876738, in both orders |
| `big128` through `big4096` | A normalized number of the stated bit length and a word divisor of at least 2 |

To measure the change without rebuilding the compiler,
[benchmark.py](benchmark.py) reads the **complete `Native.hs` module** at
each revision and compiles both into one standalone executable. It renames
the modules and adapts their imports to the GHC 9.12 namespace:
`GHC.Internal.Bignum.*` becomes `GHC.Num.*`, and
`GHC.Internal.{Prim,Types,Tuple}` becomes `GHC.{Prim,Types,Tuple}`. It also
checks that both revisions use the same `WordSize.h`. The algorithm bodies
are unchanged by these compatibility adjustments.

The word fixtures call the two versions of `bignat_gcd_word_word` directly
with unboxed operands. For the multiword fixtures, the harness explicitly
composes each version's native remainder and word-GCD routines:

```text
gcd(big, word) = native_word_gcd(word, native_rem_word(big, word))
```

This includes the native remainder cost for valid multiword inputs and
avoids accidentally measuring the installed compiler's GMP remainder
helper. The installed public `Integer` and `Natural` implementations remain
as supplied by the binary distribution. Thus this measures the changed
backend code compiled by GHC 9.12.2; it does not measure an application built
with a fully patched compiler or a GCD between two multiword operands.

The timing and validation procedure was:

1. Generate each corpus and check both implementations against public
   `Integer` GCD before starting either timer. Each word corpus has 8,192
   pairs; each multiword corpus has 1,024 pairs.
2. Calibrate the iteration count using the patched version, targeting
   75 ms of CPU time with a minimum of 200,000 calls. Both versions then
   use that same count, cycling over the corpus.
3. Run 15 paired samples per fixture, alternating which version runs first
   and changing the corpus and checksum seed between samples. The timed
   loops are marked `NOINLINE` and consume results in a checksum.
4. Record CPU time, monotonic wall time, allocation counters and garbage
   collections. Explicit garbage collections occur outside the timed
   region; no timed sample had a garbage collection. The small allocation
   counters include measurement bookkeeping.

Across the 480 recorded measurements, all paired checksums matched. Corpus
validation performed **1,638,400 input-pair checks per version**, including
the calibration corpora; this count includes repeated operands. CPU and
wall-time ratios agreed. Separately, the committed
[nativeWordGcd regression test](../nativeWordGcd.hs) passed 503,172 checks
on the complete patched module compiled with the same namespace
adaptation, using an independent Euclidean reference. Those checks cover
all pairs from 0 through 255, word boundaries, and generated inputs.

These measurements describe one machine, one compiler and these input
distributions. The intervals quantify variation within this run; they do
not establish portability. Other architectures, 32-bit words, full GHC
build integration and application-level effects remain unmeasured. The
results above supersede earlier extracted-function timings, whose boxing
and input-generation overhead obscured the small fast-path regressions.

To reproduce the benchmark, use Python 3, Git and an existing **64-bit GHC
9.12.x** installation with its bundled libraries (`base`, `array`,
`ghc-internal` and `ghc-bignum`). GHC 9.12.2 reproduces the recorded compiler
version. Run from the root of this checkout, which must contain both source
commits, and replace the executable path:

```sh
python3 testsuite/tests/lib/integer/bench-native-gcd/benchmark.py \
  --ghc /path/to/ghc-9.12.2/bin/ghc \
  --before 65bcf9e9116c3a8170d3a7e568f2a35f4bd7c3b8 \
  --after daf277c904b19b371cad15ef61e1cf98fa7afd7b \
  --output /tmp/native-gcd-results \
  --samples 15 \
  --target-ms 75
```

The command compiles the standalone harness, checks its corpora, runs the
paired timings and writes `summary.json`, `samples.csv`, `build.log`,
`run.stderr` and the build artifacts under the output directory. It does
not install packages or rebuild GHC. For a quick functional check, use
`--samples 2 --target-ms 5`; use the longer run for performance comparisons.

The checked-in [summary](results-apple-m4-max/summary.json) records the
source revisions and SHA-256 hashes, the environment, validation counts,
full-precision timings and intervals. The [raw samples](results-apple-m4-max/samples.csv)
record every measured pair, call count, checksum and runtime counter.
Together with [the runner](benchmark.py) and [the harness](Main.hs), these
are the evidence behind the tables above.
