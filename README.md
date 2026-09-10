# evm-abi-benchmarks

Cross-language benchmarks for EVM ABI encoding/decoding: the **Lean** codec
in [`evm-abi-lean`](https://github.com/yihuang/evm-abi-lean) (its `main`
branch, over lean-binary's `main`) against **go-ethereum's `abi` package**
(the mainstream Go ABI implementation).  Same shapes, same sizes, same µs/op
methodology.

```
lean/   Bench.lean — the Lean benchmark (lake project depending on evm-abi-lean)
go/     main.go   — the go-ethereum mirror (go-ethereum v1.13.14)
```

## Run

```bash
# Lean — fetches evm-abi-lean (resolved in lean/lake-manifest.json), builds and runs
cd lean && lake build bench && ./.lake/build/bin/bench

# Go
cd go && go build -o bench . && ./bench

# both, then print the Lean-vs-Go table below
./scripts/bench_diff.py
```

Both print sizes; Go's sizes are Lean + 32 (its `Arguments.Pack` wraps a
single top-level dynamic argument in an offset word — the bytes are
otherwise identical).

The comparable rows are also emitted as machine-readable
`BENCH <key> <µs/op> <bytes>` lines (the same keys on both sides);
`scripts/bench_diff.py` runs both binaries, joins them on the key, and
regenerates the table below.  Pass two captured outputs as arguments
instead to diff without re-running (`./scripts/bench_diff.py lean.txt go.txt`).

`lean/lakefile.toml` tracks `main`, which brings lean-binary's `main` in
transitively; run `lake update` to move to the branch tips.

## Methodology

* Both binaries compiled, run on the same machine, alternating run by run so
  drift hits both columns equally.
* 20 reps per case, reported as µs/op; each table cell is the median of twenty
  full runs.  `./scripts/bench_diff.py --runs 20` does the medianing and prints
  the spread below, so the table and the claims about it come out of one
  command.
* **Measured** run-to-run spread over those twenty runs, `(max−min)/median`
  per row: Lean **0–25%** (median row 12%), go-ethereum **9–33%** (median row
  15%).  Go is the noisier column on eight of the twelve rows.  A row sitting
  near the 1.25× parity band can change verdict on the Go column alone, with
  nothing on the Lean side moving — `decode flat 500` and `decode flat 2000`
  each did so between twenty-run measurements taken minutes apart, so twenty
  runs narrows those two rows without settling them.
* The Lean rows are the `ValBA` runtime value family throughout — `encode`
  and `decodeStrict`, over packed `ByteArray` payloads — not the `List UInt8`
  specification the proofs are stated over.  The bench prints both, but only
  the runtime one is keyed into the table: timing the specification against
  go-ethereum would compare a Go encoder with a Lean *specification*.
* go-ethereum's `Pack`/`Unpack` go through reflection; that overhead is
  part of the real-world cost.

Absolute µs are machine-specific; the ratios are the robust claim.

## Numbers (Apple Silicon, median of twenty runs)

| shape | Lean fast/ValBA | go-ethereum | Lean vs Go |
|---|---|---|---|
| encode flat `bytes[]` 500 | 20 | 150 | 7.5× ahead |
| encode flat 2000 | 80 | 604 | 7.5× ahead |
| encode `uint256[]` 1000 | 17 | 72 | 4.2× ahead |
| encode nest depth 50 | 7 | 104 | 14.9× ahead |
| encode nest depth 200 | 28 | 1213 | 43.3× ahead |
| decode flat 500 (ValBA) | 54 | 70 | 1.3× ahead |
| decode flat 2000 (ValBA) | 222 | 273 | **parity** |
| decode `uint256[]` 2000 (ValBA) | 64 | 83 | 1.3× ahead |
| encode unaligned 2000 | 88 | 469 | 5.3× ahead |
| decode unaligned 2000 (ValBA) | 254 | 286 | **parity** |
| encode `bytes32[]` 2000 | 15 | 170 | 11.3× ahead |
| decode `bytes32[]` 2000 (ValBA) | 170 | 147 | **parity** |

Encoding is **a size pass and a write pass**, and no intermediate structure
at all.  The first pass computes every dynamic subvalue's encoded size
bottom-up, one node per subvalue; the second writes the whole encoding
forward into a buffer sized exactly once, reading each offset word off that
size tree in `O(1)`.  go-ethereum's `pack` instead re-appends the tail at
every level, which is `O(n·d)` in the nesting depth — the gap the `nest` rows
measure (43× at depth 200).

Two more things earn the flat rows.  An ABI word is four `UInt64` limbs
rather than a `Nat`, so no word round-trips through a bignum, and words are
pushed a limb at a time, so length and offset words stop recopying the bytes
already written.  Payloads move by one copy each: a `bytes32[]` element is a
32-byte copy, a `bytes` element is its length word, payload and padding.

Getting there took the whole ladder — a fused arm per shape first (`bytes32[]`
148 → 13 µs/op, `flat 2000` 298 → 82), then the general encoder that subsumed
them (`nest 200` 50 → 28).  The one measured wrong turn is worth recording:
computing tail sizes on demand per head slot, rather than into a tree, made
`nest 200` **51 → 372 µs/op** — each offset re-walks its whole subtree, which
is far worse than the structure-visit count suggests.

Faster word *arithmetic* would not show up here.  The codec only ever converts
words — never computes with them — so rewriting `UInt256`'s bitwise and
arithmetic operations to work on limbs, worth 55–170× in lean-binary's own
bench, moves every row in this table by less than noise.

## What the shapes test

* **flat `bytes[]`** — constant factor.  Offsets come off the size tree and
  each payload moves by one copy, in a single forward pass; go-ethereum
  copies `[]byte` slices through its reflective packer.
* **`uint256[]`** — full-width words, limbs on the Lean side vs Go's C-level
  `big.Int`.
* **nested tuples** `(bytes, (bytes, …))` — asymptotics.  go-ethereum's
  `pack` is `O(n·d)` in the depth; Lean's size tree makes every offset
  `O(1)`, so the encode stays linear and pulls away as depth grows.
* **decode** — the `ValBA` rows use packed `ByteArray` payloads (one
  `extract` per payload); go-ethereum slices the input.  Both are at or just
  ahead of parity, and both are ~18× faster than Lean's `List UInt8` decode.
* **unaligned 100-byte payloads** — the zero padding (28 bytes per element)
  is checked by index (`allZerosBA`) on the Lean side, no list built.
* **`bytes32[]`** — fixed-word payloads.  Encode is one 32-byte copy per
  element with no offsets to compute at all, since the elements are static.
  Decode reads one length word for a whole array rather than one per element,
  which makes it the control: the row that should not move, and does not.
