# Arkworks R1CS Primitive Costs

Quick reference for constraint costs of common arkworks operations.

## Field Operations (FpVar)

| Operation | Constraints | Notes |
|-----------|-------------|-------|
| Addition/Subtraction | 0 | Linear combinations are free |
| Multiplication | 1 | `a × b = c` |
| Division | 1 | Via inverse witness + multiplication |
| Inverse | 1 | Witness `a⁻¹`, constrain `a × a⁻¹ = 1` |
| Square | 1 | Same as multiplication |
| Conditional select | 1 | `b × (x - y) + y = out` |
| Equality check | 1 | `(a - b) × inv = 1` or `a - b = 0` |
| Assert equal | 1 | Direct constraint |
| Constant multiplication | 0 | Absorbed into linear combination |

## Boolean Operations

| Operation | Constraints | Notes |
|-----------|-------------|-------|
| Boolean allocation | 1 | `b × (1 - b) = 0` |
| AND | 1 | `a × b = c` |
| OR | 1 | `a + b - a×b = c` |
| XOR | 1 | `a + b - 2×a×b = c` |
| NOT | 0 | `1 - a` (linear) |
| Conditional select | 1 | Same as field |

## Integer Types (UInt8, UInt32, UInt64)

**WARNING**: These are expensive because they require bit decomposition!

| Type | Allocation | Per Comparison | Per Addition |
|------|------------|----------------|--------------|
| UInt8 | 8 | 8 | ~16 |
| UInt32 | 32 | 32 | ~64 |
| UInt64 | 64 | 64 | ~128 |

**Why so expensive?**
- Each bit needs a Boolean constraint
- Comparisons require bit-by-bit evaluation
- Arithmetic must handle carry propagation

**Recommendation**: Use `FpVar` when possible. Only use UInt types when you actually need:
- Unsigned overflow semantics
- Bit-level operations
- Range proofs

## Elliptic Curve Operations

| Operation | Constraints (Affine) | Constraints (Projective) |
|-----------|---------------------|-------------------------|
| Point addition | 3-4 | 12-16 |
| Point doubling | 4-5 | 8-10 |
| Scalar mul (256-bit, naive) | ~1,500 | ~3,500 |
| Scalar mul (256-bit, windowed) | ~600-800 | ~1,200-1,500 |
| Equality check | 2 | 6+ |
| On-curve check | 2-3 | 3-4 |

**Key insight**: For fixed-base scalar multiplication (e.g., generator G), precompute tables as constants (0 constraints for the table!) and use conditional selection.

## Hash Functions

| Hash | Constraints | Notes |
|------|-------------|-------|
| Poseidon (rate 2, capacity 1) | ~300 | Per absorption |
| Poseidon (per additional element) | ~100 | Incremental |
| Pedersen commitment | ~600-800 | Per field element |
| SHA-256 | ~25,000 | Very expensive in R1CS |
| Blake2s | ~15,000 | Expensive |

**Recommendation**: Always use Poseidon for in-circuit hashing.

## Signature Verification

| Scheme | Constraints | Notes |
|--------|-------------|-------|
| Schnorr (single) | ~35,000 | 2 scalar muls + Poseidon |
| ECDSA | ~50,000+ | More expensive than Schnorr |
| EdDSA | ~40,000 | Similar to Schnorr |

## Array/Selection Operations

These depend on array size N:

| Operation | Constraints | Formula |
|-----------|-------------|---------|
| Select from array | O(N) | N equality checks + N conditional selects |
| Update array element | O(N) | Similar to select |
| Linear scan | O(N) | Per element: comparison + conditional |

For N_MAX = 9 in poker circuits:
- `select_player`: ~1,800 constraints
- `update_player`: ~1,800 constraints
- `conditionally_select_player`: ~600 constraints

## Comparison Operations

| Operation | FpVar | UInt64 |
|-----------|-------|--------|
| `a == b` | 1 | 64 |
| `a < b` | N/A | ~128 |
| `a <= b` | N/A | ~128 |
| `a != b` | 2 | 65 |

**Note**: FpVar doesn't have natural ordering (field elements), so `<` comparisons require representing as integers.

## Cost Multipliers

Watch for these patterns that multiply constraint counts:

| Pattern | Multiplier |
|---------|------------|
| Loop over N_MAX | ×9 |
| Loop over DECK_SIZE | ×52 |
| Per-bit operations | ×64 (for UInt64) |
| Per-player operations | ×N_MAX |
| Nested loops | ×N² |

## Quick Estimation Formula

```
Total ≈ Σ (base_cost × call_count × loop_multiplier)
```

Example for a circuit with:
- 1 Schnorr verify: 35,000
- 6 select_player calls: 6 × 1,800 = 10,800
- 10 UInt64 comparisons: 10 × 64 = 640
- 1 Poseidon hash: 300

**Estimated total**: ~46,740 constraints
