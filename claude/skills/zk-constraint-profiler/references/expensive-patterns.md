# Expensive Patterns in ZK Circuits

Common bottleneck patterns that cause constraint explosion in arkworks R1CS circuits.

## Pattern 1: UInt64 for Simple Counters

**Symptom**: High constraint count for simple arithmetic operations

**Bad Pattern**:
```rust
// Each comparison costs 64 constraints!
let counter = UInt64::new_witness(cs.clone(), || Ok(count))?;
let max = UInt64::constant(10);
counter.is_leq(&max)?;  // 64+ constraints
```

**Why it's expensive**:
- UInt64 requires 64 Boolean constraints for allocation
- Each comparison operates bit-by-bit
- Arithmetic requires carry propagation

**Cost**: 64-128 constraints per operation

**Fix**: Use FpVar when you don't need overflow semantics or bit operations.

---

## Pattern 2: Repeated Array Operations

**Symptom**: O(N) cost multiplied by many calls

**Bad Pattern**:
```rust
// Called 6 times in unified step circuit
for action in actions {
    let player = select_player(&players, &actor_idx)?;  // ~1,800 each
    // ... use player
}
```

**Why it's expensive**:
- `select_player` iterates over all N_MAX players
- Each call: N equality checks + N conditional selects
- Total: 6 × 1,800 = 10,800 constraints

**Cost**: O(N × call_count)

**Fix**: Factor out common selections, compute once and reuse.

---

## Pattern 3: Redundant Gadget Calls

**Symptom**: Same computation appears in multiple branches

**Bad Pattern**:
```rust
// Each action computes next_to_act independently
let fold_output = compute_fold_output(&state)?;    // calls next_to_act
let check_output = compute_check_output(&state)?;  // calls next_to_act again
let call_output = compute_call_output(&state)?;    // calls next_to_act again
// ...
```

**Why it's expensive**:
- `next_to_act_gadget` costs ~800 constraints
- Called 6 times = 4,800 constraints
- But result is the same!

**Cost**: Multiplied by number of branches

**Fix**: Compute once before branching, pass result to all branches.

---

## Pattern 4: Nested Loops Over N_MAX

**Symptom**: O(N²) constraint explosion

**Bad Pattern**:
```rust
for i in 0..N_MAX {
    for j in 0..N_MAX {
        // Some operation
        let player_i = select_player(&players, &i)?;
        let player_j = select_player(&players, &j)?;
    }
}
```

**Why it's expensive**:
- N_MAX = 9, so 81 iterations
- Each iteration may have expensive operations
- Quadratic growth

**Cost**: O(N²) × operation_cost

**Fix**: Restructure algorithm to avoid nested loops, or use batch operations.

---

## Pattern 5: Bit Decomposition in Hot Loops

**Symptom**: Scalar multiplication costs multiplied by loop count

**Bad Pattern**:
```rust
for i in 0..52 {  // DECK_SIZE
    let scalar_bits = card_value[i].to_bits_le()?;  // 256 Booleans
    let result = point.scalar_mul_le(scalar_bits.iter())?;  // ~800 per
}
```

**Why it's expensive**:
- Bit decomposition: 256 constraints
- Scalar mul: ~800 constraints
- ×52 cards = 54,912 constraints

**Cost**: (bit_decomp + scalar_mul) × loop_count

**Fix**: Use windowed scalar multiplication, batch operations, or precomputed tables.

---

## Pattern 6: IVC Uniformity Forcing

**Symptom**: All branches computed even when only one is taken

**Context**: IVC/Nova requires uniform constraint count across all steps.

**Pattern**:
```rust
// Must compute ALL action outputs for uniform constraint count
let fold_output = compute_fold_output(&state)?;
let check_output = compute_check_output(&state)?;
let call_output = compute_call_output(&state)?;
let bet_output = compute_bet_output(&state)?;
let raise_output = compute_raise_output(&state)?;
let advance_output = compute_advance_output(&state)?;

// Then select the right one
let output = select_from_outputs(&action_type, &all_outputs)?;
```

**Why it's expensive**:
- All 6 actions computed regardless of which is taken
- No short-circuiting possible
- Constraint count = sum of all branches

**Cost**: Sum of all branch costs

**Fix**: This is often unavoidable for IVC. Focus on optimizing each branch and factoring out common operations.

---

## Pattern 7: String/Array Encoding in Circuit

**Symptom**: High allocation costs for structured data

**Bad Pattern**:
```rust
// Encoding a string character by character
let chars: Vec<UInt8<F>> = string.bytes()
    .map(|b| UInt8::new_witness(cs.clone(), || Ok(b)))
    .collect()?;
```

**Why it's expensive**:
- Each UInt8 = 8 constraints
- 100-char string = 800 constraints just for allocation
- Plus comparison/processing costs

**Cost**: 8 × string_length + processing

**Fix**: Hash strings outside circuit, only verify hash inside.

---

## Pattern 8: Full Struct Selection

**Symptom**: Selecting between complex structs

**Bad Pattern**:
```rust
// PlayerStateVar has 6 FpVar fields
let selected = conditionally_select_player(&condition, &player_a, &player_b)?;
// 6 conditional selects = 6 constraints
```

**Why it multiplies**:
- Each field in struct needs conditional select
- PlayerStateVar: 6 fields × 1 constraint = 6
- ActionOutput: maybe 10+ fields

**Cost**: field_count × selection_count

**Fix**: Only select the fields you actually need.

---

## Pattern 9: Poseidon Over Large Inputs

**Symptom**: Hash costs dominate for large state

**Pattern**:
```rust
// Hashing all player states
let mut sponge = PoseidonSponge::new(&params);
for player in players.iter() {  // N_MAX iterations
    sponge.absorb(&player.chips)?;
    sponge.absorb(&player.status)?;
    // ... 6 fields per player
}
let hash = sponge.squeeze()?;
```

**Why it's expensive**:
- Poseidon: ~300 per absorption round
- 9 players × 6 fields = 54 absorptions
- ~16,200 constraints for hashing alone

**Cost**: ~300 × num_elements

**Fix**: Hash merkle root of state instead of all fields. Use efficient encoding.

---

## Pattern 10: Unnecessary Constraint Mode

**Symptom**: Constants allocated as witnesses

**Bad Pattern**:
```rust
// Allocating known constants as witnesses
let zero = FpVar::new_witness(cs.clone(), || Ok(F::zero()))?;
let one = FpVar::new_witness(cs.clone(), || Ok(F::one()))?;
```

**Why it's wasteful**:
- Witnesses cost constraints for nothing
- Constants are free!

**Cost**: Unnecessary witness constraints

**Fix**: Use `FpVar::constant(F::zero())` or `FpVar::Constant(value)`.

---

## Detection Checklist

When analyzing a circuit, check for:

- [ ] UInt64/UInt32/UInt8 usage (could be FpVar?)
- [ ] Loops over N_MAX or DECK_SIZE
- [ ] Repeated calls to same gadget
- [ ] Nested loops (O(N²) patterns)
- [ ] Scalar multiplication in loops
- [ ] All-branches-computed patterns (IVC)
- [ ] Large struct selections
- [ ] Hash operations over many elements
- [ ] Constants allocated as witnesses
