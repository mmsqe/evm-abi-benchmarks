import EvmAbi

/-!
# Bench

A benchmark for evm-abi-lean's runtime codec — `encode` and `decodeStrict`
over `ValBA`, packed `ByteArray` payloads throughout — against go-ethereum's
`abi` package on the same shapes.  Build and run with

```bash
lake build bench && ./.lake/build/bin/bench
```

The `List UInt8` specification (`Spec.encode`, `Spec.encodeByteArray`,
`Spec.decodeStrict`) is printed alongside each row for scale, but only the
runtime codec is keyed into the cross-language table: timing the
specification against a Go encoder compares a Go encoder with a Lean
*specification*, which is what the keys were fixed to stop doing.

The shapes are chosen because they fail differently:

* **flat `bytes[]`** — both encoders are linear here, so this measures the
  constant factor: the specification builds the whole buffer as a
  `List UInt8` (a cons cell and a boxed byte per byte) and converts at the
  end, while the builder writes into a pre-sized `ByteArray`.

* **nested tuples** `(bytes, (bytes, (…)))` — this measures the asymptotics.
  `Spec.encode` concatenates with `++` at every level, so a `d`-deep value has
  its bytes re-copied `d` times (`O(n · d)`); the builder makes
  concatenation an `O(1)` constructor, so it stays linear.

* **ValBA vs Val** — the runtime value family (`ValBA`) against the list
  payloads of `Ty.Val`, on flat `bytes[]`: aligned 256-byte elements (the
  zero padding is empty) and unaligned 100-byte elements (padding 28 per
  element).  Both decoders check that padding by index — `allZerosBA`, no
  list — so what the unaligned row still measures is the payload: a packed
  `ByteArray` window against a cons list.

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

/-- A flat `bytes[]` of `payload`-byte elements. -/
def flatValOf (payload : Nat) (p : payload < 2 ^ 64)
    (n : Nat) (h : n < 2 ^ 64) : flatTy.Val :=
  ⟨List.replicate n (mkBytesOf payload p), by simpa using h⟩

/-- A `bytes` value of `n` bytes. -/
def mkBytes (n : Nat) (h : n < 2 ^ 64) : Ty.Val .bytes :=
  ⟨List.replicate n 7, by simpa using h⟩

/-- A `uint256[]` of full-width values — token amounts, hashes and addresses
are all above `2 ^ 63`, so every word goes through `Nat`'s bignum path.  This
is the case `Binary.Fast`'s chunked encoder exists for. -/
def wideTy : Ty := .array (.uint 256)

def wideVal (n : Nat) (h : n < 2 ^ 64) : wideTy.Val :=
  ⟨List.replicate n ⟨0x123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0,
    by decide⟩, by simpa using h⟩

/-- The same value, packed (`ValBA`). -/
def wideValBA (n : Nat) (h : n < 2 ^ 64) : ValBA wideTy :=
  ⟨List.replicate n ⟨0x123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0,
    by decide⟩, by simpa using h⟩

/-- `nest k = (bytes, (bytes, … ))`, `k` tuples deep. -/
def nest : Nat → Ty
  | 0 => .tuple [.bytes]
  | k + 1 => .tuple [.bytes, nest k]

def nestVal : (k : Nat) → (nest k).Val
  | 0 => (mkBytes 256 (by decide), ())
  | k + 1 => (mkBytes 256 (by decide), nestVal k, ())

/-- The same value, packed (`ValBA`). -/
def nestValBA : (k : Nat) → ValBA (nest k)
  | 0 => (mkBytesBAOf 256 (by decide), ())
  | k + 1 => (mkBytesBAOf 256 (by decide), nestValBA k, ())

def reps : Nat := 20

def timeCore (label : String) (act : Unit → Nat) : IO (Nat × Nat) := do
  let t0 ← IO.monoNanosNow
  let mut checksum := 0
  for _ in [0:reps] do
    checksum := checksum + act ()
  let t1 ← IO.monoNanosNow
  let us := (t1 - t0) / (1000 * reps)
  let byteCount := checksum / reps
  IO.println s!"  {label}: {us} us/op  ({byteCount} bytes)"
  pure (us, byteCount)

/-- `timeIt` plus a machine-readable `BENCH <key> <us/op> <bytes>` line that
`bench_diff.py` joins against the Go bench (same keys, same shapes). -/
def timeItKey (key label : String) (act : Unit → Nat) : IO Unit := do
  let (us, byteCount) ← timeCore label act
  if ! key.isEmpty then
    IO.println s!"BENCH {key} {us} {byteCount}"

def timeIt (label : String) (act : Unit → Nat) : IO Unit := do
  let _ ← timeCore label act
  pure ()

def benchTy (key label : String) (t : Ty) (v : t.Val) (vba : ValBA t) : IO Unit := do
  IO.println label
  timeIt "spec  Spec.encode ++ toByteArray" (fun _ => (Spec.encode t v).toByteArray.size)
  timeIt "      Spec.encodeByteArray      " (fun _ => (Spec.encodeByteArray t v).size)
  timeItKey key "fast  encode (ValBA)            " (fun _ => (encode t vba).size)

/-- Decode the same buffer both ways; the `bytes` count is the buffer size. -/
def benchDecode (label : String) (ba : ByteArray) : IO Unit := do
  IO.println s!"{label} ({ba.size} bytes)"
  timeIt "spec  Spec.decodeStrict   (list)" (fun _ =>
    if (Spec.decodeStrict flatTy ba.data.toList).isSome then ba.size else 0)
  timeIt "fast  decodeStrictBA       " (fun _ =>
    if (decodeStrictBA flatTy ba).isSome then ba.size else 0)

def benchValBA (decodeKey encodeKey : String) (payload : Nat) (p : payload < 2 ^ 64) (n : Nat) (h : n < 2 ^ 64) : IO Unit := do
  let v := flatValOf payload p n h
  let vba := flatValBAOf payload p n h
  -- Not `Spec.encodeByteArray flatTy v`: that shares the subexpression with the
  -- encode row below, which then times a field read and prints 0 us/op.  Same
  -- bytes by `Spec.encodeByteArray_eq`.
  let ba := (Spec.encode flatTy v).toByteArray
  IO.println s!"-- {n} elements ({ba.size} bytes)"
  timeIt "decodeStrictBA (List)  " (fun _ =>
    if (decodeStrictBA flatTy ba).isSome then ba.size else 0)
  timeItKey decodeKey "decodeStrict (BA)    " (fun _ =>
    if (decodeStrict flatTy ba).isSome then ba.size else 0)
  timeIt "Spec.encodeByteArray (List) " (fun _ => (Spec.encodeByteArray flatTy v).size)
  timeItKey encodeKey "encode (BA)          " (fun _ => (encode flatTy vba).size)
  IO.println s!"  agree: {(encode flatTy vba) == (Spec.encodeByteArray flatTy v)} ∧ {(decodeStrict flatTy ba).isSome == (decodeStrictBA flatTy ba).isSome}"

/-- `bytesN` payloads — the fixed-word decode.  `decodeStrictBA` reads each
payload as a ≤32-cell cons list (`windowList`) and repacks it;
`decodeStrict` extracts the payload in one `copySlice` with the padding
checked by index (`allZerosBA`), so this row isolates the list round-trip. -/
def benchBytesN (decodeKey encodeKey : String) (n : Nat) (h : n < 2 ^ 64) : IO Unit := do
  let t : Ty := .array (.bytesN 32)
  let el : Ty.Val (.bytesN 32) := ⟨List.replicate 32 7, by simp⟩
  let v : t.Val := ⟨List.replicate n el, by simpa using h⟩
  let ba := Spec.encodeByteArray t v
  let elba : ValBA (.bytesN 32) := ⟨(List.replicate 32 7).toByteArray, by
    simp [Binary.ByteArray.size_eq_toList_length]⟩
  let vba : ValBA t := ⟨List.replicate n elba, by simpa using h⟩
  IO.println s!"-- bytes32[] × {n} ({ba.size} bytes)"
  timeIt "decodeStrictBA (List)  " (fun _ =>
    if (decodeStrictBA t ba).isSome then ba.size else 0)
  timeItKey decodeKey "decodeStrict (BA)    " (fun _ =>
    if (decodeStrict t ba).isSome then ba.size else 0)
  timeItKey encodeKey "encode (BA)          " (fun _ => (encode t vba).size)
  IO.println s!"  agree: {(decodeStrict t ba).isSome == (decodeStrictBA t ba).isSome}"

def main : IO Unit := do
  IO.println "== flat bytes[], 256-byte elements (constant factor) =="
  benchTy "encode/flat/500" "-- 500 elements"  flatTy (flatValOf 256 (by decide) 500 (by decide))
    (flatValBAOf 256 (by decide) 500 (by decide))
  benchTy "encode/flat/2000" "-- 2000 elements" flatTy (flatValOf 256 (by decide) 2000 (by decide))
    (flatValBAOf 256 (by decide) 2000 (by decide))
  IO.println "== uint256[], full-width values (bignum word encoding) =="
  benchTy "encode/uint256/1000" "-- 1000 words" wideTy (wideVal 1000 (by decide))
    (wideValBA 1000 (by decide))
  -- Decode: on `main` the monadic walkers allocate a closure per element; the
  -- `monad-walkers` branch routes this through the `@[csimp]` fast path
  -- (`decodeBAValFast`).  Full-width words make each element expensive (~1 µs
  -- of bignum decoding), so the closure overhead is small relative to the work.
  let wba := encode wideTy (wideValBA 2000 (by decide))
  IO.println s!"-- 2000 words, decode ({wba.size} bytes)"
  timeItKey "decode/uint256/2000" "decodeStrict (BA)    " (fun _ =>
    if (decodeStrict wideTy wba).isSome then wba.size else 0)
  IO.println "== nested tuples (bytes, (bytes, ...)) (asymptotics) =="
  benchTy "encode/nest/50" "-- depth 50"  (nest 50)  (nestVal 50) (nestValBA 50)
  benchTy "encode/nest/200" "-- depth 200" (nest 200) (nestVal 200) (nestValBA 200)
  -- the two encoders must agree byte for byte — this is `encodeByteArray_eq`
  let v := flatValOf 256 (by decide) 50 (by decide)
  let w := nestVal 20
  IO.println "== decode: list cursors vs offset cursors =="
  -- `Spec.decodeStrict` converts the buffer to a list and slices it; `decodeStrictBA`
  -- walks the same buffer by offset.  Same theorem, same answer.
  benchDecode "-- 500 elements"  (Spec.encodeByteArray flatTy (flatValOf 256 (by decide) 500 (by decide)))
  benchDecode "-- 2000 elements" (Spec.encodeByteArray flatTy (flatValOf 256 (by decide) 2000 (by decide)))
  IO.println s!"agree(flat)   = {(Spec.encode flatTy v).toByteArray == Spec.encodeByteArray flatTy v}"
  IO.println s!"agree(nested) = {(Spec.encode (nest 20) w).toByteArray == Spec.encodeByteArray (nest 20) w}"
  IO.println "== ValBA vs Val: aligned 256-byte payloads (pad 0) =="
  benchValBA "decode/flat/500" "" 256 (by decide) 500 (by decide)
  benchValBA "decode/flat/2000" "" 256 (by decide) 2000 (by decide)
  IO.println "== ValBA vs Val: unaligned 100-byte payloads (pad 28 — the list-free pad check) =="
  benchValBA "decode/unaligned/2000" "encode/unaligned/2000" 100 (by decide) 2000 (by decide)
  IO.println "== bytesN: fixed-word payloads (list round-trip vs one extract) =="
  benchBytesN "decode/bytes32/2000" "encode/bytes32/2000" 2000 (by decide)
