#!/usr/bin/env python3
"""Build & run both benchmarks and print the cross-language diff table (the
numbers that go in the README "Numbers" section).

Usage:
    ./bench_diff.py                  # build & run both benches once, then diff
    ./bench_diff.py --runs 20        # the README methodology: median of N runs,
                                     # with the per-row spread that justifies it
    ./bench_diff.py lean.txt go.txt  # diff previously captured outputs

Both benches emit `BENCH <key> <µs/op> <bytes>` lines for the comparable
rows (the same keys on both sides); this script joins them on the key and
classifies each ratio as behind / parity / ahead.
"""

import re
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# |lean/go - 1| below this ⇒ parity; above it the multiple is reported.
PARITY_BAND = 1.25

# Rows of the README table, in order: (BENCH key, human label).
ROWS = [
    ("encode/flat/500", "encode flat `bytes[]` 500"),
    ("encode/flat/2000", "encode flat 2000"),
    ("encode/uint256/1000", "encode `uint256[]` 1000"),
    ("encode/nest/50", "encode nest depth 50"),
    ("encode/nest/200", "encode nest depth 200"),
    ("decode/flat/500", "decode flat 500 (ValBA)"),
    ("decode/flat/2000", "decode flat 2000 (ValBA)"),
    ("decode/uint256/2000", "decode `uint256[]` 2000 (ValBA)"),
    ("encode/unaligned/2000", "encode unaligned 2000"),
    ("decode/unaligned/2000", "decode unaligned 2000 (ValBA)"),
    ("encode/bytes32/2000", "encode `bytes32[]` 2000"),
    ("decode/bytes32/2000", "decode `bytes32[]` 2000 (ValBA)"),
]

BENCH_RE = re.compile(r"^BENCH (\S+) (\d+) (\d+)$")


def parse(text: str) -> dict:
    """Parse `BENCH <key> <us/op> <bytes>` lines into {key: (us, bytes)}."""
    out = {}
    for line in text.splitlines():
        m = BENCH_RE.match(line)
        if m:
            out[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    return out


def verdict(lean_us: int, go_us: int) -> str:
    ratio = lean_us / go_us
    if ratio > PARITY_BAND:
        return f"{ratio:.1f}× behind"
    if ratio < 1 / PARITY_BAND:
        return f"{1 / ratio:.1f}× ahead"
    return "**parity**"


LEAN_CMD = "cd lean && lake build bench && ./.lake/build/bin/bench"
GO_CMD = "cd go && go build -o bench . && ./bench"


def sample(cmd: str, quiet: bool = False) -> dict:
    """One run of one bench binary, parsed."""
    proc = subprocess.run(["bash", "-lc", cmd], cwd=ROOT, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        sys.exit(f"{cmd} failed ({proc.returncode})")
    if not quiet:
        sys.stdout.write(proc.stdout)
        sys.stdout.flush()
    return parse(proc.stdout)


def spread(vs: list[int]) -> float:
    """Run-to-run range as a percentage of the median."""
    m = statistics.median(vs)
    return 100 * (max(vs) - min(vs)) / m if m else 0.0


def main() -> None:
    runs = 1
    if "--runs" in sys.argv:
        i = sys.argv.index("--runs")
        runs = int(sys.argv[i + 1])
        del sys.argv[i:i + 2]

    if len(sys.argv) == 3:
        leans = [parse(Path(sys.argv[1]).read_text())]
        gos = [parse(Path(sys.argv[2]).read_text())]
    elif runs == 1:
        print("=== Lean ===")
        leans = [sample(LEAN_CMD)]
        print("\n=== Go (go-ethereum) ===")
        gos = [sample(GO_CMD)]
    else:
        # build once, then alternate so drift hits both columns equally
        sample(LEAN_CMD, quiet=True)
        sample(GO_CMD, quiet=True)
        leans, gos = [], []
        for i in range(runs):
            leans.append(sample(LEAN_CMD, quiet=True))
            gos.append(sample(GO_CMD, quiet=True))
            print(f"run {i + 1}/{runs}", file=sys.stderr, flush=True)

    missing = [k for k, _ in ROWS if any(k not in r for r in leans + gos)]
    if missing:
        sys.exit(f"missing BENCH rows: {missing}")

    print("\n| shape | Lean fast/ValBA | go-ethereum | Lean vs Go |")
    print("|---|---|---|---|")
    for key, label in ROWS:
        lu = int(statistics.median(r[key][0] for r in leans))
        gu = int(statistics.median(r[key][0] for r in gos))
        print(f"| {label} | {lu} | {gu} | {verdict(lu, gu)} |")

    if runs > 1:
        ls = {k: spread([r[k][0] for r in leans]) for k, _ in ROWS}
        gs = {k: spread([r[k][0] for r in gos]) for k, _ in ROWS}
        print(f"\nRun-to-run spread over {runs} runs, (max-min)/median per row:")
        print(f"  Lean  {min(ls.values()):.0f}-{max(ls.values()):.0f}% "
              f"(median row {statistics.median(ls.values()):.0f}%)")
        print(f"  Go    {min(gs.values()):.0f}-{max(gs.values()):.0f}% "
              f"(median row {statistics.median(gs.values()):.0f}%)")
        print("\n| shape | Lean spread | Go spread |")
        print("|---|---|---|")
        for key, label in ROWS:
            print(f"| {label} | {ls[key]:.0f}% | {gs[key]:.0f}% |")


if __name__ == "__main__":
    main()
