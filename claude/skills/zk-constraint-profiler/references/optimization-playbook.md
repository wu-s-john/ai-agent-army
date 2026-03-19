# ZK Circuit Optimization Playbook

Given a bottleneck, here are specific optimization strategies with code examples.

## Optimization 1: Replace UInt64 with FpVar

**When**: Counter or index doesn't need overflow semantics or bit operations

**Before** (~64 constraints per comparison):
```rust
let counter = UInt64::new_witness(cs.clone(), || Ok(count))?;
let limit = UInt64::constant(100);
let is_valid = counter.is_leq(&limit)?;
```

**After** (~1-2 constraints):
```rust
let counter = FpVar::new_witness(cs.clone(), || Ok(F::from(count)))?;
let limit = FpVar::constant(F::from(100u64));

// For equality check (1 constraint)
counter.enforce_equal(&limit)?;

// For range proof, use dedicated range gadget or handle at protocol level
```

**Savings**: ~62 constraints per operation

**Caveat**: FpVar doesn't have natural ordering. For `<` comparisons, consider:
- Checking at the protocol level (outside circuit)
- Using a range proof gadget
- Encoding comparison result as a witness and verifying

---

## Optimization 2: Factor Out Common Computations

**When**: Same gadget called multiple times with same inputs

**Before** (6 × 800 = 4,800 constraints):
```rust
fn compute_fold_output(state: &GameStateVar) -> Result<ActionOutput, SynthesisError> {
    let next_actor = next_to_act_gadget(&state.players, &state.actor)?;
    // ... use next_actor
}

fn compute_check_output(state: &GameStateVar) -> Result<ActionOutput, SynthesisError> {
    let next_actor = next_to_act_gadget(&state.players, &state.actor)?;  // Same computation!
    // ... use next_actor
}
// ... repeated for all 6 actions
```

**After** (1 × 800 = 800 constraints):
```rust
fn unified_step(state: &GameStateVar) -> Result<ActionOutput, SynthesisError> {
    // Compute once
    let next_actor = next_to_act_gadget(&state.players, &state.actor)?;

    // Pass to all action computations
    let fold_output = compute_fold_output(state, &next_actor)?;
    let check_output = compute_check_output(state, &next_actor)?;
    // ...
}
```

**Savings**: (N-1) × gadget_cost, where N = number of branches

---

## Optimization 3: Batch Array Operations

**When**: Multiple select/update operations on same array

**Before** (2 × 1,800 = 3,600 constraints):
```rust
let actor = select_player(&players, &actor_idx)?;
let target = select_player(&players, &target_idx)?;
```

**After** (share work, ~2,400 constraints):
```rust
// Custom batch select that shares equality checks
fn select_two_players(
    players: &[PlayerStateVar; N_MAX],
    idx1: &FpVar,
    idx2: &FpVar,
) -> Result<(PlayerStateVar, PlayerStateVar), SynthesisError> {
    let mut player1 = PlayerStateVar::zero();
    let mut player2 = PlayerStateVar::zero();

    for i in 0..N_MAX {
        let i_var = FpVar::constant(F::from(i as u64));
        let is_idx1 = i_var.is_eq(idx1)?;
        let is_idx2 = i_var.is_eq(idx2)?;

        player1 = conditionally_select(&is_idx1, &players[i], &player1)?;
        player2 = conditionally_select(&is_idx2, &players[i], &player2)?;
    }

    Ok((player1, player2))
}
```

**Savings**: Shared loop overhead, ~30-40%

---

## Optimization 4: Use Constants Instead of Witnesses

**When**: Values are known at compile time

**Before** (unnecessary witness constraints):
```rust
let zero = FpVar::new_witness(cs.clone(), || Ok(F::zero()))?;
let one = FpVar::new_witness(cs.clone(), || Ok(F::one()))?;
```

**After** (0 constraints):
```rust
let zero = FpVar::constant(F::zero());
let one = FpVar::constant(F::one());
```

**Savings**: Eliminates all unnecessary witness constraints

---

## Optimization 5: Precomputed Tables for Scalar Mul

**When**: Fixed-base scalar multiplication (e.g., generator point)

**Before** (naive scalar mul, ~800 constraints):
```rust
let scalar_bits = scalar.to_bits_le()?;
let result = generator.scalar_mul_le(scalar_bits.iter())?;
```

**After** (precomputed table, ~450 constraints):
```rust
// Precompute at setup: [2⁰·G, 2¹·G, ..., 2²⁵⁵·G]
// Store as constants (0 constraints)
const G_POWERS: [AffinePoint; 256] = precompute_powers(G);

// In circuit: conditional select and add
fn fixed_base_scalar_mul(
    scalar_bits: &[Boolean<F>],
) -> Result<PointVar, SynthesisError> {
    let mut result = PointVar::zero();
    for (i, bit) in scalar_bits.iter().enumerate() {
        let g_power = PointVar::constant(G_POWERS[i]);
        let selected = conditionally_select(bit, &g_power, &PointVar::zero())?;
        result = result.add(&selected)?;
    }
    Ok(result)
}
```

**Savings**: ~40-50% for scalar multiplication

---

## Optimization 6: Lazy Evaluation / Conditional Computation

**When**: Some computations only needed in certain branches (non-IVC)

**Before** (always compute everything):
```rust
let expensive_value = expensive_computation(&inputs)?;
let result = conditionally_select(&condition, &expensive_value, &default)?;
```

**After** (only compute when needed):
```rust
// Only works if you can verify correctness another way
let result = if condition.value().unwrap_or(false) {
    expensive_computation(&inputs)?
} else {
    default.clone()
};
// Add constraint to verify result is correct
```

**Caveat**: This breaks uniform constraint count for IVC. Only use in non-IVC contexts.

---

## Optimization 7: Reduce Struct Selection

**When**: Selecting between complex structs but only using some fields

**Before** (select entire struct, 6 constraints):
```rust
let selected_player = conditionally_select_player(&condition, &player_a, &player_b)?;
// But only use selected_player.chips
```

**After** (select only needed field, 1 constraint):
```rust
let selected_chips = FpVar::conditionally_select(
    &condition,
    &player_a.chips,
    &player_b.chips
)?;
```

**Savings**: (total_fields - used_fields) constraints

---

## Optimization 8: Hash Compression

**When**: Large state needs to be hashed

**Before** (hash all fields individually):
```rust
let mut sponge = PoseidonSponge::new(&params);
for player in players.iter() {
    sponge.absorb(&player.chips)?;      // 54 absorptions
    sponge.absorb(&player.status)?;
    // ...
}
let hash = sponge.squeeze()?;  // ~16,200 constraints
```

**After** (merkle tree or batched hashing):
```rust
// Hash each player first (outside or batched)
let player_hashes: Vec<FpVar> = players.iter()
    .map(|p| hash_player(p))
    .collect()?;

// Then hash the hashes (fewer absorptions)
let mut sponge = PoseidonSponge::new(&params);
for hash in player_hashes.iter() {
    sponge.absorb(hash)?;  // Only 9 absorptions
}
let root = sponge.squeeze()?;  // ~2,700 constraints
```

**Savings**: Significant for large state (~80% reduction)

---

## Optimization 9: Affine vs Projective Coordinates

**When**: Elliptic curve operations

**Before** (projective, ~12-16 per addition):
```rust
let result = point_a.add(&point_b)?;  // Projective addition
```

**After** (mixed addition with affine, ~3-4 per addition):
```rust
// Use affine for one operand when possible
let result = projective_point.add_affine(&affine_point)?;
```

**Savings**: 60-75% per point addition

**See**: `docs/circuit_cookbook.md` Appendix D for detailed EC optimization strategies.

---

## Optimization 10: Windowed Scalar Multiplication

**When**: Variable-base scalar multiplication

**Before** (double-and-add, ~1,500 constraints):
```rust
let scalar_bits = scalar.to_bits_le()?;
let result = point.scalar_mul_le(scalar_bits.iter())?;
```

**After** (4-bit windowed, ~800 constraints):
```rust
// Process 4 bits at a time
const WINDOW_SIZE: usize = 4;

fn windowed_scalar_mul(
    point: &PointVar,
    scalar_bits: &[Boolean<F>],
) -> Result<PointVar, SynthesisError> {
    // Precompute [1·P, 2·P, ..., 15·P]
    let table = precompute_window_table(point)?;

    let mut result = PointVar::zero();
    for window in scalar_bits.chunks(WINDOW_SIZE) {
        // 4 doublings
        for _ in 0..WINDOW_SIZE {
            result = result.double()?;
        }
        // Table lookup and add
        let index = bits_to_index(window)?;
        let selected = table_lookup(&table, &index)?;
        result = result.add(&selected)?;
    }
    Ok(result)
}
```

**Savings**: ~45% for 256-bit scalars

---

## Decision Tree: Which Optimization?

```
Is the bottleneck...

├── Integer operations?
│   └── Can you use FpVar instead? → Optimization 1
│
├── Repeated gadget calls?
│   └── Same inputs? → Optimization 2 (factor out)
│
├── Array operations?
│   └── Multiple accesses? → Optimization 3 (batch)
│
├── Known constants?
│   └── Allocated as witnesses? → Optimization 4
│
├── Scalar multiplication?
│   ├── Fixed base? → Optimization 5 (precomputed)
│   └── Variable base? → Optimization 10 (windowed)
│
├── Struct selection?
│   └── Using all fields?
│       ├── Yes → OK
│       └── No → Optimization 7 (select only needed)
│
├── Hashing large state?
│   └── Can restructure? → Optimization 8 (compression)
│
└── Elliptic curve operations?
    └── Mixed coordinates possible? → Optimization 9
```

---

## Measuring Impact

Always verify optimizations with before/after constraint counts:

```rust
#[test]
fn measure_optimization_impact() {
    // Before
    let cs_before = ConstraintSystem::<Fr>::new_ref();
    old_implementation(cs_before.clone()).unwrap();
    let before = cs_before.num_constraints();

    // After
    let cs_after = ConstraintSystem::<Fr>::new_ref();
    new_implementation(cs_after.clone()).unwrap();
    let after = cs_after.num_constraints();

    println!("Before: {} constraints", before);
    println!("After: {} constraints", after);
    println!("Savings: {} constraints ({:.1}%)",
        before - after,
        100.0 * (before - after) as f64 / before as f64
    );

    // Verify both are satisfied with same inputs
    assert!(cs_before.is_satisfied().unwrap());
    assert!(cs_after.is_satisfied().unwrap());
}
```
