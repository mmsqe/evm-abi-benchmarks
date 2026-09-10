#!/usr/bin/env python3
"""A/B two evm-abi-lean revisions on the Lean bench.

Row medians drift 10-30% between runs, so both binaries are built up front and
run alternately; a row counts as moved only when the ranges do not overlap.
A build target is a git revision or a directory -- prefer the directory, since
Lake can only fetch a revision the lakefile's URL already has.

Usage:
    ./bench_ab.py --build REV_OR_DIR OUT
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

# One `[[require]]` block: `(?!\[)` stops the scan at the next section header.
REQUIRE = re.compile(r"\[\[require\]\]\n(?:(?!\[)[^\n]*\n)*")
# Its `rev` value, leaving the rest of the block -- the URL included -- alone.
REV = re.compile(r'(\n\s*rev\s*=\s*")[^"]*(")')


def sh(cmd: str, cwd: Path) -> None:
    p = subprocess.run(["bash", "-lc", cmd], cwd=cwd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.stderr.write(p.stdout + p.stderr)
        sys.exit(f"{cmd} failed ({p.returncode})")


def pin(text: str, target: str) -> str:
    """Point the abi-lean require at a directory, or at a git revision."""
    blocks = [m for m in REQUIRE.finditer(text) if 'name = "abi-lean"' in m[0]]
    if len(blocks) != 1:
        sys.exit(f"expected one abi-lean require in the lakefile, found {len(blocks)}")
    m = blocks[0]
    if Path(target).is_dir():
        block = f'[[require]]\nname = "abi-lean"\npath = "{Path(target).resolve()}"'
    else:
        block, n = REV.subn(lambda r: r[1] + target + r[2], m[0])
        if n != 1:
            sys.exit(f"the abi-lean require has no `rev` to pin to {target}")
    tail = m[0][len(m[0].rstrip()):]  # blank lines after the block, kept as-is
    return text[:m.start()] + block.rstrip() + tail + text[m.end():]


def build(target: str, out: Path) -> None:
    """Build lean/bench against one abi-lean revision or checkout.

    The lakefile and manifest are restored on the way out, so the pin never
    reaches a commit.  A directory is built in place, filling its own `.lake`.
    """
    lakefile = LEAN / "lakefile.toml"
    saved = {p: p.read_text() if p.exists() else None
             for p in (lakefile, LEAN / "lake-manifest.json")}
    try:
        lakefile.write_text(pin(lakefile.read_text(), target))
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
    ap.add_argument("--build", nargs=2, metavar=("REV_OR_DIR", "OUT"),
                    help="build lean/bench against a revision or a checkout "
                         "directory, and write the binary to OUT")
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
