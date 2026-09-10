#!/usr/bin/env python3
"""A/B two evm-abi-lean revisions on the Lean bench.

`bench_diff.py` answers "how does Lean compare to Go"; this answers "did this
commit move Lean".  Comparing two separately-taken runs cannot: row medians
drift 10-30% between runs on an idle machine, enough to invent a regression or
to hide one.  So both binaries are built up front and then run *alternately* in
one process, and a row counts as moved only when the two ranges do not overlap
-- not when the medians differ by some percentage.

Only the Lean side is built.  For a Lean-vs-Lean comparison the go-ethereum
column cancels, and building it would pull in cgo for nothing.

Usage:
    ./bench_ab.py --build REV OUT        # build the Lean bench against REV
    ./bench_ab.py BASE_BIN HEAD_BIN [--runs N]
"""

import argparse
import collections
import re
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEAN = ROOT / "lean"
BENCH_RE = re.compile(r"^BENCH (\S+) (\d+) (\d+)$")

# The `rev` value of the abi-lean require, leaving the rest of the block -- the
# URL included -- alone.  `(?!\[)` stops the scan at the next section header, so
# a later require cannot be hit by mistake.
REV = re.compile(r'(name = "abi-lean"(?:\n(?!\[)[^\n]*)*?\n\s*rev\s*=\s*")[^"]*(")')


def sh(cmd: str, cwd: Path) -> None:
    p = subprocess.run(["bash", "-lc", cmd], cwd=cwd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.stderr.write(p.stdout + p.stderr)
        sys.exit(f"{cmd} failed ({p.returncode})")


def build(rev: str, out: Path) -> None:
    """Build lean/bench against one abi-lean revision.

    The lakefile and manifest are restored on the way out; `.lake/packages` is
    left checked out at `rev`, which the next `lake update` corrects.
    """
    lakefile = LEAN / "lakefile.toml"
    saved = {p: p.read_text() if p.exists() else None
             for p in (lakefile, LEAN / "lake-manifest.json")}
    try:
        text, n = REV.subn(lambda m: m[1] + rev + m[2], lakefile.read_text())
        if n != 1:
            sys.exit(f"no `rev` in the abi-lean require of {lakefile}")
        lakefile.write_text(text)
        sh("lake update", LEAN)
        sh("lake build bench", LEAN)
        shutil.copy(LEAN / ".lake/build/bin/bench", out)
    finally:
        for p, text in saved.items():
            if text is None:
                p.unlink(missing_ok=True)
            else:
                p.write_text(text)


def sample(binary: Path) -> dict:
    """One run of one bench binary, as {row: µs/op}."""
    p = subprocess.run([str(binary)], capture_output=True, text=True)
    if p.returncode != 0:
        sys.stderr.write(p.stdout + p.stderr)
        sys.exit(f"{binary} failed ({p.returncode})")
    rows = {m[1]: int(m[2]) for m in map(BENCH_RE.match, p.stdout.splitlines()) if m}
    if not rows:
        sys.exit(f"no BENCH lines from {binary}: is this the Lean bench binary?")
    return rows


def collect(base: Path, head: Path, runs: int) -> dict:
    """{row: (base samples, head samples)}, alternated so drift hits both."""
    rows = collections.defaultdict(lambda: ([], []))
    for i in range(runs):
        for column, exe in ((0, base), (1, head)):
            for row, us in sample(exe).items():
                rows[row][column].append(us)
        print(f"run {i + 1}/{runs}", file=sys.stderr, flush=True)
    return rows


def report(rows: dict, runs: int) -> int:
    """Print the table; return how many rows got slower on disjoint ranges."""
    both = sorted(row for row, (b, h) in rows.items() if b and h)
    if skipped := sorted(set(rows) - set(both)):
        print(f"missing from one build, skipped: {', '.join(skipped)}", file=sys.stderr)

    print(f"\n{runs} alternating runs per build, µs/op\n")
    print(f"{'row':<24} {'base':>6} {'head':>6} {'delta':>8}  {'verdict':<12} ranges")
    moved = 0
    for row in both:
        b, h = rows[row]
        mb, mh = statistics.median(b), statistics.median(h)
        delta = 100 * (mh - mb) / mb if mb else 0.0
        # Overlapping ranges mean the two builds produced runs of equal cost, so
        # a difference in medians is a sampling artefact rather than a finding.
        disjoint = min(h) > max(b) or min(b) > max(h)
        verdict = ("SLOWER" if delta > 0 else "faster") if disjoint else "overlapping"
        if disjoint and delta > 0:
            moved += 1
        print(f"{row:<24} {mb:>6g} {mh:>6g} {delta:>+7.1f}%  {verdict:<12} "
              f"{min(b)}-{max(b)} vs {min(h)}-{max(h)}")
    print(f"\n{moved} row(s) got slower on non-overlapping ranges.")
    return moved


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--build", nargs=2, metavar=("REV", "OUT"),
                    help="build lean/bench against REV, write the binary to OUT")
    ap.add_argument("--runs", type=int, default=40,
                    help="alternating runs per build (default: %(default)s)")
    ap.add_argument("bins", nargs="*", metavar="BIN", help="BASE_BIN HEAD_BIN")
    args = ap.parse_args()

    if args.build:
        build(args.build[0], Path(args.build[1]).resolve())
    elif len(args.bins) == 2:
        base, head = (Path(b).resolve() for b in args.bins)
        sys.exit(1 if report(collect(base, head, args.runs), args.runs) else 0)
    else:
        ap.error("give BASE_BIN and HEAD_BIN, or --build REV OUT")


if __name__ == "__main__":
    main()
