#!/usr/bin/env python3
r"""Benchmark the native GCD patch without rebuilding GHC.

Requires git, Python 3, and a GHC 9.12 binary distribution (base and array only).
Run from any directory, for example:

  python3 benchmark.py --ghc /path/to/ghc --before daf277c^ --after daf277c \
      --output /tmp/native-gcd-results

The complete Native.hs modules at both revisions are compiled with -O2. Only
module names/imports are adapted to GHC 9.12's namespace. Both versions share
pre-generated inputs; the timed loop calls unboxed backend functions directly.
Multiword fixtures explicitly use the native remainder kernel as well as GCD,
so they do not silently time the installed compiler's GMP remainder helper.

This measures the native backend on the host architecture/compiler. It does
not benchmark an application built with the patched GHC or alter installed
Integer/Natural instances. No source compiler build or package installation
is performed. Build artifacts and raw/summary results go into --output.
"""
import argparse
import csv
import hashlib
import json
import math
import platform
import random
import shutil
import statistics
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = "libraries/ghc-internal/src/GHC/Internal/Bignum/Backend/Native.hs"
HEADER = "libraries/ghc-internal/include/WordSize.h"


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def capture(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def adapt(source, name):
    source = source.replace("module GHC.Internal.Bignum.Backend.Native where", "module " + name + " where")
    source = source.replace("GHC.Internal.Bignum.", "GHC.Num.")
    for module in ["Prim", "Types", "Tuple"]:
        source = source.replace("GHC.Internal." + module, "GHC." + module)
    return source


def summarize(rows):
    grouped = {}
    for row in rows:
        grouped.setdefault(row["case"], {}).setdefault(int(row["sample"]), {})[row["version"]] = row
    results = {}
    for name, pairs in grouped.items():
        ratios, before, after, wall_ratios, allocations, gcs = [], [], [], [], [], []
        for versions in pairs.values():
            b, a = versions["Before"], versions["After"]
            assert b["checksum"] == a["checksum"] and b["calls"] == a["calls"], name
            bn, an = float(b["cpu_ns_per_call"]), float(a["cpu_ns_per_call"])
            before.append(bn)
            after.append(an)
            ratios.append(bn / an)
            wall_ratios.append(float(b["wall_ns_per_call"]) / float(a["wall_ns_per_call"]))
            allocations.extend(float(r["allocated_bytes"]) / int(r["calls"]) for r in [b, a])
            gcs.extend(int(r["timed_gcs"]) for r in [b, a])
        rng = random.Random(20261009)
        bootstrap = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
        results[name] = {
            "paired_samples": len(pairs),
            "before_median_ns": statistics.median(before),
            "after_median_ns": statistics.median(after),
            "median_paired_speedup": statistics.median(ratios),
            "bootstrap_95_percent_interval": [bootstrap[250], bootstrap[9749]],
            "median_wall_speedup": statistics.median(wall_ratios),
            "maximum_allocated_bytes_per_call": max(allocations),
            "maximum_timed_gcs": max(gcs),
        }
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ghc", default="ghc")
    parser.add_argument("--before", required=True)
    parser.add_argument("--after", default="HEAD")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--samples", type=int, default=15)
    parser.add_argument("--target-ms", type=float, default=75)
    args = parser.parse_args()
    if args.samples < 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("use at least two samples and a positive finite target duration")
    ghc = shutil.which(args.ghc)
    if ghc is None:
        parser.error("GHC executable not found; supply --ghc /path/to/an/installed/ghc")
    # Keep the bin/ghc symlink: some binary distributions locate lib/ relative to it.
    ghc = str(Path(ghc).absolute())
    version = capture(ghc, "--numeric-version")
    if not version.startswith("9.12."):
        parser.error("this compatibility harness currently supports GHC 9.12.x")
    repo = Path(capture("git", "-C", str(HERE), "rev-parse", "--show-toplevel"))
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    build = out / "build"
    build.mkdir(exist_ok=True)
    provenance = {}
    for label, ref in [("Before", args.before), ("After", args.after)]:
        rev = capture("git", "-C", str(repo), "rev-parse", "--verify", ref + "^{commit}")
        source = subprocess.check_output(["git", "-C", str(repo), "show", rev + ":" + SOURCE], text=True)
        generated = adapt(source, "Native" + label)
        (build / ("Native" + label + ".hs")).write_text(generated)
        provenance[label] = {"revision": rev, "source_sha256": digest(source), "adapted_sha256": digest(generated)}
    if provenance["Before"]["source_sha256"] == provenance["After"]["source_sha256"]:
        parser.error("the selected revisions have identical Native.hs sources")
    before_header = capture("git", "-C", str(repo), "show", provenance["Before"]["revision"] + ":" + HEADER)
    after_header = capture("git", "-C", str(repo), "show", provenance["After"]["revision"] + ":" + HEADER)
    if before_header != after_header:
        parser.error("WordSize.h differs between revisions; inspect the ABI before comparing")
    (build / "WordSize.h").write_text(after_header + "\n")
    shutil.copyfile(HERE / "Main.hs", build / "Main.hs")
    command = [ghc, "-O2", "-fforce-recomp", "-rtsopts", "-package", "ghc-internal", "-package", "ghc-bignum",
               "-package", "array", "-i" + str(build), "-I" + str(build), "-outputdir", str(build),
               str(build / "Main.hs"), "-o", str(build / "native-gcd-bench")]
    print("Compiling both complete Native backend modules with GHC " + version, flush=True)
    with (out / "build.log").open("w") as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    run_command = [str(build / "native-gcd-bench"), str(args.samples), str(args.target_ms), "+RTS", "-T"]
    print("Running paired samples; raw output: " + str(out / "samples.csv"), flush=True)
    with (out / "samples.csv").open("w") as data, (out / "run.stderr").open("w") as errors:
        subprocess.run(run_command, stdout=data, stderr=errors, check=True)
    rows = list(csv.DictReader((out / "samples.csv").open()))
    summary = summarize(rows)
    if len(summary) != 16 or any(r["paired_samples"] != args.samples for r in summary.values()):
        raise RuntimeError("benchmark output is incomplete")
    result = {
        "environment": {"platform": platform.platform(), "machine": platform.machine(),
                        "cpu": capture("sysctl", "-n", "machdep.cpu.brand_string") if platform.system() == "Darwin" else platform.processor(),
                        "ghc": capture(ghc, "--version"),
                        "ghc_info": capture(ghc, "--info")},
        "source": provenance, "compile_command": command, "run_command": run_command,
        "main_sha256": digest((HERE / "Main.hs").read_text()),
        "runner_sha256": digest(Path(__file__).read_text()),
        "header_sha256": digest(after_header + "\n"),
        "validation": {"input_pair_checks_per_version": (args.samples + 1) * (12 * 8192 + 4 * 1024),
                       "all_paired_checksums_match": True},
        "method": "Complete native modules; pre-generated inputs checked against Integer gcd outside timing; direct unboxed calls; alternating order; changing corpus and nonce per sample; calibrated call count; CPU and wall clocks; paired medians and 10000 bootstrap resamples.",
        "scope": "64-bit native backend, host GHC 9.12 code generation. Multiword cases compose native remainder and word GCD on valid multiword operands. No full patched compiler, public Integer instance, or GMP-backend speedup is measured. Timed allocation statistics include fixed measurement bookkeeping.",
        "results": summary,
    }
    (out / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    for name, r in summary.items():
        print("{}: {:.2f} -> {:.2f} ns, {:.3f}x [{:.3f}, {:.3f}]".format(
            name, r["before_median_ns"], r["after_median_ns"], r["median_paired_speedup"], *r["bootstrap_95_percent_interval"]))


if __name__ == "__main__":
    main()
