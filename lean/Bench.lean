import EvmAbi

/-!
# Bench

A benchmark for evm-abi-lean's runtime codec — `encode` and `decodeStrict`
over `ValBA`, packed `ByteArray` payloads throughout — against go-ethereum's
`abi` package on the same shapes.  Build and run with

```bash
lake build bench && ./.lake/build/bin/bench
```

Every row here is keyed (`BENCH <key> <us/op> <bytes>`) and has a counterpart
in the Go bench.  The `List UInt8` specification is **not** timed: comparing
`Spec.encode` against a Go encoder compares a Go encoder with a Lean
*specification*, and the spec-vs-runtime ladder is evm-abi-lean's own
regression bench (`lake build bench` there), not a cross-language claim.
The spec is still used here to build decode inputs and to cross-check the
runtime codec's output — once each, outside the timing loop.

The shapes are chosen because they fail differently:

* **flat `bytes[]`** — constant factor: offsets come off the size tree and
  each payload moves by one copy, against go-ethereum's reflective packer.

* **`uint256[]`** — full-width words, limbs against Go's `big.Int`.

* **nested tuples** `(bytes, (bytes, (…)))` — asymptotics.  go-ethereum's
  `pack` re-appends the tail at every level (`O(n · d)`); the size tree makes
  every offset `O(1)`, so the encode stays linear.

* **unaligned 100-byte payloads** — the zero padding (28 bytes per element)
  is checked by index (`allZerosBA`), no list built.

* **`bytes32[]`** — fixed-word payloads, static elements, no offsets at all.

Run this interpreted (`lake env lean --run Bench.lean`) and the numbers
invert: `ByteArray.emptyWithCapacity` and `ByteArray.push` are `@[extern]`,
so the builder only pays off in compiled code.
-/

open EvmAbi
open EvmAbi.Ty
-- the runtime codec (`encode`, `decodeStrict`) and the list-valued walker
-- (`decodeStrictBA`) live in their own namespaces since evm-abi-lean#42;
-- `Spec.*` stays reachable through `EvmAbi`.
open EvmAbi.Codec
open EvmAbi.Codec.ByteArray

def flatTy : Ty := .array .bytes

/-- A `bytes` value of `payload` bytes, packed (`ValBA` family). -/
def mkBytesBAOf (payload : Nat) (p : payload < 2 ^ 64) : {bs : ByteArray // bs.size < 2 ^ 64} :=
  ⟨(List.replicate payload 7).toByteArray, by
    simp [Binary.ByteArray.size_eq_toList_length, List.length_replicate]
    exact p⟩

/-- A flat `bytes[]` of `payload`-byte packed payloads. -/
def flatValBAOf (payload : Nat) (p : payload < 2 ^ 64)
    (n : Nat) (h : n < 2 ^ 64) : {vs : List (ValBA .bytes) // vs.length < 2 ^ 64} :=
  ⟨List.replicate n (mkBytesBAOf payload p), by simpa using h⟩

/-- A `bytes` value of `payload` bytes. -/
def mkBytesOf (payload : Nat) (p : payload < 2 ^ 64) : Ty.Val .bytes :=
  ⟨List.replicate payload 7, by simpa using p⟩

/-- A flat `bytes[]` of `payload`-byte elements.  Only used to build the
decode input and the correctness cross-check, never timed. -/
def flatValOf (payload : Nat) (p : payload < 2 ^ 64)
    (n : Nat) (h : n < 2 ^ 64) : flatTy.Val :=
  ⟨List.replicate n (mkBytesOf payload p), by simpa using h⟩

/-- A `uint256[]` of full-width values — token amounts, hashes and addresses
are all above `2 ^ 63`, so every word goes through `Nat`'s bignum path.  This
is the case `Binary.Fast`'s chunked encoder exists for. -/
-- `Ty.uint`'s width is a byte length since evm-abi-lean#45, so `uint256` is
-- `.uint 32`.
def wideTy : Ty := .array (.uint 32)

/-- The full-width `uint256[]`, packed (`ValBA`). -/
def wideValBA (n : Nat) (h : n < 2 ^ 64) : ValBA wideTy :=
  ⟨List.replicate n ⟨0x123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0,
    by decide⟩, by simpa using h⟩

/-- `nest k = (bytes, (bytes, … ))`, `k` tuples deep. -/
def nest : Nat → Ty
  | 0 => .tuple .bytes []
  | k + 1 => .tuple .bytes [nest k]

/-- The nested value, packed (`ValBA`). -/
def nestValBA : (k : Nat) → ValBA (nest k)
  | 0 => (mkBytesBAOf 256 (by decide), ())
  | k + 1 => (mkBytesBAOf 256 (by decide), nestValBA k, ())

def reps : Nat := 20

/-- Time `act` over `reps` reps and print `us/op`, plus the machine-readable
`BENCH <key> <us/op> <bytes>` line that `bench_diff.py` joins against the Go
bench (same keys, same shapes).  An empty `key` prints the timing without
keying it into the table. -/
def timeIt (key label : String) (act : Unit → Nat) : IO Unit := do
  let t0 ← IO.monoNanosNow
  let mut checksum := 0
  for _ in [0:reps] do
    checksum := checksum + act ()
  let t1 ← IO.monoNanosNow
  let us := (t1 - t0) / (1000 * reps)
  let byteCount := checksum / reps
  IO.println s!"  {label}: {us} us/op  ({byteCount} bytes)"
  if ! key.isEmpty then
    IO.println s!"BENCH {key} {us} {byteCount}"

/-- One encode row. -/
def benchEncode (key label : String) (t : Ty) (vba : ValBA t) : IO Unit := do
  IO.println label
  timeIt key "encode (ValBA)       " (fun _ => (encode t vba).size)

/-- A decode row and an encode row over the same shape, plus the check that
the runtime codec reproduces the specification's bytes.  `ba` must not be
`encode t vba`: that would share the subexpression with the encode row, which
then times a field read and prints 0 us/op. -/
def benchRoundTrip (decodeKey encodeKey label : String) (t : Ty) (vba : ValBA t)
    (ba : ByteArray) : IO Unit := do
  IO.println label
  timeIt decodeKey "decodeStrict (BA)    " (fun _ =>
    if (decodeStrict t ba).isSome then ba.size else 0)
  timeIt encodeKey "encode (BA)          " (fun _ => (encode t vba).size)
  IO.println s!"  agree: {(encode t vba) == ba}"

/-- Flat `bytes[]` of `payload`-byte elements — aligned at 256, unaligned at
100 (28 bytes of padding per element, checked by index via `allZerosBA`). -/
def benchFlat (decodeKey encodeKey : String) (payload : Nat) (p : payload < 2 ^ 64)
    (n : Nat) (h : n < 2 ^ 64) : IO Unit := do
  let ba := (Spec.encode flatTy (flatValOf payload p n h)).toByteArray
  benchRoundTrip decodeKey encodeKey s!"-- {n} elements ({ba.size} bytes)"
    flatTy (flatValBAOf payload p n h) ba

/-- `bytesN` payloads — the fixed-word decode.  `decodeStrict` extracts each
payload in one `copySlice`, and reads one length word for the whole array
rather than one per element. -/
def benchBytesN (decodeKey encodeKey : String) (n : Nat) (h : n < 2 ^ 64) : IO Unit := do
  let t : Ty := .array (.bytesN 32)
  -- the payload bound is now stated against `Width.bytes`, which `simp` does
  -- not unfold on its own
  let el : Ty.Val (.bytesN 32) := ⟨List.replicate 32 7, by decide⟩
  let elba : ValBA (.bytesN 32) := ⟨(List.replicate 32 7).toByteArray, by
    simp [Binary.ByteArray.size_eq_toList_length]; decide⟩
  let ba := Spec.encodeByteArray t ⟨List.replicate n el, by simpa using h⟩
  benchRoundTrip decodeKey encodeKey s!"-- bytes32[] × {n} ({ba.size} bytes)"
    t ⟨List.replicate n elba, by simpa using h⟩ ba

def main : IO Unit := do
  IO.println "== flat bytes[], 256-byte elements (constant factor) =="
  benchEncode "encode/flat/500" "-- 500 elements"  flatTy
    (flatValBAOf 256 (by decide) 500 (by decide))
  benchEncode "encode/flat/2000" "-- 2000 elements" flatTy
    (flatValBAOf 256 (by decide) 2000 (by decide))
  IO.println "== uint256[], full-width values (bignum word encoding) =="
  benchEncode "encode/uint256/1000" "-- 1000 words" wideTy (wideValBA 1000 (by decide))
  -- Decode: on `main` the monadic walkers allocate a closure per element; the
  -- `monad-walkers` branch routes this through the `@[csimp]` fast path
  -- (`decodeBAValFast`).  Full-width words make each element expensive (~1 µs
  -- of bignum decoding), so the closure overhead is small relative to the work.
  let wba := encode wideTy (wideValBA 2000 (by decide))
  IO.println s!"-- 2000 words, decode ({wba.size} bytes)"
  timeIt "decode/uint256/2000" "decodeStrict (BA)    " (fun _ =>
    if (decodeStrict wideTy wba).isSome then wba.size else 0)
  IO.println "== nested tuples (bytes, (bytes, ...)) (asymptotics) =="
  benchEncode "encode/nest/50" "-- depth 50"  (nest 50)  (nestValBA 50)
  benchEncode "encode/nest/200" "-- depth 200" (nest 200) (nestValBA 200)
  IO.println "== aligned 256-byte payloads (pad 0) =="
  benchFlat "decode/flat/500" "" 256 (by decide) 500 (by decide)
  benchFlat "decode/flat/2000" "" 256 (by decide) 2000 (by decide)
  IO.println "== unaligned 100-byte payloads (pad 28 — the list-free pad check) =="
  benchFlat "decode/unaligned/2000" "encode/unaligned/2000" 100 (by decide) 2000 (by decide)
  IO.println "== bytesN: fixed-word payloads =="
  benchBytesN "decode/bytes32/2000" "encode/bytes32/2000" 2000 (by decide)
