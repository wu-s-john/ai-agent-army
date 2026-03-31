---
name: snark-guidelines
description: SNARK circuit development cookbook for arkworks R1CS systems. Use when writing or reviewing circuit code, implementing gadgets, debugging constraint failures, working with transcripts/sponges, or doing any ZK proof system work. Covers mirror-first architecture, field handling, AllocVar patterns, Boolean operations, constraint hygiene, and PR checklists.
---

# SNARK Development Guidelines: Cookbook & Reference

Comprehensive guidelines for writing SNARK code with native/circuit parity. Core principle: **Write one specification and implement it twice** — a native backend (CPU code) and a circuit backend (constraints). Keep them behaviorally identical and prove they stay in lockstep with tests and logging.

## TL;DR (Pin These Rules)

1. **One spec, two backends**
2. **Never cast Fr -> FpVar**. Use bits or non-native fields
3. **Fix encodings**. Same byte order and object order for transcript absorption
4. **Constrain everything**. No unconstrained witness values
5. **Test to fail**. Every rule has a negative test
6. **Audit transcripts**. Byte-for-byte logs match across backends
7. **Keep circuits static**. No secret-dependent branches
8. **Minimize public inputs** and version everything

---

## 1. Architecture: "One Spec, Two Backends"

**Rule A1**: Design the verifier once as a pure function over an abstract transcript and abstract group/scalar ops. Then provide:
- **Native backend**: concrete types (PoseidonSponge, G, G::ScalarField)
- **Circuit backend**: gadget types (PoseidonSpongeVar, CurveVar, bit-decomposed scalars or non-native field vars)

This pattern eliminates copy-paste divergence and keeps the native and circuit code literally the same algorithm instantiated over two type families.

## 2. Data Representation & Encoding (Critical)

You will typically have two prime fields:
- **G::ScalarField** (e.g., Fr): used for exponents/scalars (Pedersen, ElGamal, MSMs)
- **G::BaseField** (e.g., Fp): coordinates of curve points, state field of Poseidon sponges, etc.

**Rule D1 (No silent cast)**: Never represent an Fr scalar as an FpVar by "conversion". If Fr != Fp, that is a change of field and can break soundness.

### Preferred Encodings:
- **Scalars (Fr) -> bits**: canonical little-endian bit-decomposition with booleanity and exact length checks; feed into scalar_mul_le gadgets
- **Alternative**: Non-native field variables (NonNativeFieldVar<Fr, Fp>) when you truly need field arithmetic over Fr in an Fp circuit (costlier, but sometimes necessary)
- **Points**: affine (x, y) over Fp. Forbid the point at infinity unless explicitly allowed; do subgroup/cofactor checks for public inputs if your curve requires it
- **Transcript**: define one canonical encoding for every absorbed object (point coordinates, scalar bits/limbs, array order, endianness) and use it everywhere

## 3. Constraint Hygiene & Equality Semantics

- Everything you compute must be constrained. Assignments/witness values without constraints are a bug
- **Booleanity & ranges**: enforce `b*(1-b)=0` for bits; for limbs, enforce range via lookups or running sums
- **No secret-dependent branching**: replace `if (secret)` with boolean gating: `out = b*x + (1-b)*y`
- **Equality of points**: use enforce_equal (or constrain both coordinates); do not rely on host-side ==

## 4. Transcript + Challenge Derivation (Determinism)

- Hash the same bytes in the same order on both backends
- Absorb points as (x, y) in an agreed order; absorb scalars as exact bitstrings (or limbs) that the circuit also allocates
- Derive the challenge c identically (same rate/capacity, same squeeze count)
- Add an "audit" mode: log the exact absorbed preimage stream (hex) on both backends and compare byte-for-byte in tests

## 5. Gadget Design Principles

- **Match native function signatures**: e.g., if native does `encrypt_one_and_combine(keys, sigma_rho, C_in, sigma_b)`, the gadget should do the same, only with circuit types (points, bits)
- **Expose scalar inputs as bits** (or non-native variables). Provide both fixed-base and variable-base MSM variants with windowing control
- **Use lookups** for small integer and membership checks when your arithmetization supports them

## 6. Testing Strategy (Must-Have)

### Positive Tests
- Random valid instances prove and verify

### Fail-to-Prove (Negative) Tests
For each relation:
- Flip a bit in sigma_b[0] -> proving must fail
- Swap transcript absorption order -> fail
- Alter one ciphertext -> fail

### Transcript Snapshot Tests
- Native vs circuit audit logs must match byte-for-byte
- Challenge equality: `c_native == c_circuit.value().unwrap()` for random instances

### Constraint Budget Regression
- Assert constraint counts (per N) to catch accidental bloat

### Property-Based Fuzzing
- Test corner cases (0, 1, max limbs, carries, edge points)

## 7. Performance Guidelines

- Prefer ZK-friendly hashes (Poseidon/Rescue/Griffin) for in-circuit commitments/transcripts
- Minimize public inputs: hash long statements to a short digest inside the circuit; expose only the digest
- Windowed MSMs: configure windows (e.g., 4-6 bits) and reuse decompositions across operations
- Cache shared sub-computations: decompose scalars once, reuse bits across all scalar muls
- If using PLONK-ish stacks, exploit lookups and custom gates for range checks and S-boxes

## 8. Recursion / IVC / Folding (if applicable)

- Keep the step circuit tiny and uniform; expose a compact accumulator/digest in public IO
- Choose recursion-friendly curves (e.g., curve cycles) if you plan to verify proofs inside proofs
- Gate expensive verifier checks carefully and reuse transcript state across steps

## 9. Ops: SRS, Versioning, Domain Separation

- **Groth16**: per-circuit trusted setup; manage keys and toxic waste; re-run if the circuit changes
- **PLONK-ish**: universal SRS; derive per-circuit proving/verifying keys
- **Version everything**: hash circuit sources and keys; include a circuit/version tag as a domain separator in public inputs/transcript

---

## Cookbook: Elliptic Curve Field Handling

When working with elliptic curve objects, discern what is scalar field and what is base field. This is critically important for scalar multiplication in SNARK circuits.

**Key Principle**: When doing SNARK circuit computations with elliptic curves, try to have the scalar fields be base fields. This makes the SNARK circuit cheaper with fewer constraints and witnesses.

```rust
// Convert scalar to bits and perform scalar multiplication
let c_bits = challenge_c.to_bits_le()?;
let b_vector_commitment_scaled = b_vector_commitment.scalar_mul_le(c_bits.iter())?;
```

## Cookbook: AllocVar Implementation

When allocating variables, implement the `AllocVar` trait:

```rust
pub struct ElGamalCiphertextVar<G: SWCurveConfig>
where
    G::BaseField: PrimeField,
{
    pub c1: ProjectiveVar<G, FpVar<G::BaseField>>,
    pub c2: ProjectiveVar<G, FpVar<G::BaseField>>,
}

impl<G: SWCurveConfig> AllocVar<ElGamalCiphertext<Projective<G>>, G::BaseField>
    for ElGamalCiphertextVar<G>
where
    G::BaseField: PrimeField,
{
    fn new_variable<T: std::borrow::Borrow<ElGamalCiphertext<Projective<G>>>>(
        cs: impl Into<gr1cs::Namespace<G::BaseField>>,
        f: impl FnOnce() -> Result<T, SynthesisError>,
        mode: AllocationMode,
    ) -> Result<Self, SynthesisError> {
        let _span =
            tracing::debug_span!(target: "legit_poker::shuffling::alloc", "alloc_elgamal_ciphertext").entered();

        let cs = cs.into().cs();
        let value = f()?;
        let ciphertext = value.borrow();

        tracing::trace!(target: "legit_poker::shuffling::alloc", "Allocating c1 ProjectiveVar");
        let c1 = ProjectiveVar::<G, FpVar<G::BaseField>>::new_variable(
            cs.clone(),
            || Ok(ciphertext.c1),
            mode,
        )?;

        tracing::trace!(target: "legit_poker::shuffling::alloc", "Allocating c2 ProjectiveVar");
        let c2 = ProjectiveVar::<G, FpVar<G::BaseField>>::new_variable(
            cs.clone(),
            || Ok(ciphertext.c2),
            mode,
        )?;

        Ok(Self { c1, c2 })
    }
}
```

- When enforcing a constraint, first write a comment expressing the mathematical equation being enforced
- Prefer `cs.enforce_constraint` over `expression.enforce_equal` for clarity on LHS vs RHS

## Cookbook: Bits-Based Allocation Pattern

```rust
pub struct SigmaProofBitsVar<G, GG, const N: usize>
where
    G: CurveGroup,
    GG: CurveVar<G, G::BaseField>,
{
    pub blinding_factor_commitment: GG,
    pub blinding_rerandomization_commitment: GG,
    pub sigma_response_b_bits: [Vec<Boolean<G::BaseField>>; N],
    pub sigma_response_blinding_bits: Vec<Boolean<G::BaseField>>,
    pub sigma_response_rerand_bits: Vec<Boolean<G::BaseField>>,
}

impl<G, GG, const N: usize> AllocVar<SigmaProof<G, N>, G::BaseField> for SigmaProofBitsVar<G, GG, N>
where
    G: CurveGroup,
    GG: CurveVar<G, G::BaseField>,
{
    fn new_variable<T: Borrow<SigmaProof<G, N>>>(
        cs: impl Into<Namespace<G::BaseField>>,
        f: impl FnOnce() -> Result<T, SynthesisError>,
        mode: AllocationMode,
    ) -> Result<Self, SynthesisError> {
        let ns = cs.into();
        let cs = ns.cs();
        let proof = f()?.borrow().clone();

        let blinding_factor_commitment =
            GG::new_variable(cs.clone(), || Ok(proof.blinding_factor_commitment), mode)?;
        let blinding_rerandomization_commitment =
            GG::new_variable(cs.clone(), || Ok(proof.blinding_rerandomization_commitment), mode)?;

        let alloc_fr_bits = |x: G::ScalarField| -> Result<Vec<Boolean<G::BaseField>>, SynthesisError> {
            let bits_le: Vec<bool> = x.into_bigint().to_bits_le();
            bits_le.into_iter()
                .map(|b| Boolean::new_variable(cs.clone(), || Ok(b), mode))
                .collect()
        };

        let mut tmp: Vec<Vec<Boolean<G::BaseField>>> = Vec::with_capacity(N);
        for i in 0..N {
            tmp.push(alloc_fr_bits(proof.sigma_response_b[i])?);
        }
        let sigma_response_b_bits: [Vec<Boolean<G::BaseField>>; N] = tmp.try_into().unwrap();

        let sigma_response_blinding_bits = alloc_fr_bits(proof.sigma_response_blinding)?;
        let sigma_response_rerand_bits   = alloc_fr_bits(proof.sigma_response_rerand)?;

        Ok(Self {
            blinding_factor_commitment,
            blinding_rerandomization_commitment,
            sigma_response_b_bits,
            sigma_response_blinding_bits,
            sigma_response_rerand_bits,
        })
    }
}
```

## Cookbook: Enforcement Patterns

```rust
// 1) Pedersen commitment side:
// Mathematical equation: com(z_b; z_s) = T_com * B^c
let lhs_com = pedersen::commit_bits(&params_var, &sigma_response_b_bits, &sigma_response_blinding_bits)?;
let rhs_com = blinding_factor_commitment.clone()
    + b_vector_commitment.scalar_mul_le(challenge_bits.iter())?;
lhs_com.enforce_equal(&rhs_com)?;

// 2) Group/ciphertext side:
// Mathematical equation: E_pk(1; z_rho) * prod C_j^{z_b[j]} = T_grp * (C'^a)^c
let lhs_grp = elgamal::encrypt_one_and_combine_bits(
    &keys_var,
    &sigma_response_rerand_bits,
    &input_ciphertexts_var,
    &sigma_response_b_bits,
)?;
let rhs_grp = blinding_rerandomization_commitment.clone()
    + (output_agg.c1.clone() + output_agg.c2.clone())
        .scalar_mul_le(challenge_bits.iter())?;
lhs_grp.enforce_equal(&rhs_grp)?;
```

## Cookbook: Boolean Operations in Circuits

The arkworks `Boolean` type uses standard Rust bitwise operators:

```rust
use ark_r1cs_std::boolean::Boolean;

// Use bitwise operators (always with references)
let and_result = (&bool_a & &bool_b)?;   // AND
let or_result = (&bool_a | &bool_b)?;    // OR
let xor_result = (&bool_a ^ &bool_b)?;   // XOR
let not_result = (!&bool_a)?;            // NOT

// These methods DON'T EXIST:
// bool_a.and(&bool_b)  -- won't compile
// bool_a.or(&bool_b)   -- won't compile
```

---

## R1CS Constraint System Debugging

### Use Namespaces
Always wrap constraint logic in descriptive namespaces using `ns!` macro:
```rust
use ark_relations::{ns, gr1cs::ConstraintSystemRef};

fn my_gadget<F: Field>(cs: ConstraintSystemRef<F>) -> Result<(), SynthesisError> {
    let cs = ns!(cs, "my_gadget");
    let cs_hash = ns!(cs, "hash_check");
    cs_hash.enforce_constraint(a, b, c)?;
    Ok(())
}
```

**Important**: `ns!` requires compile-time string constants. Do not use with dynamic strings or for simple witness allocations.

### Identify Failing Constraints
```rust
if !cs.is_satisfied()? {
    let idx = cs.which_is_unsatisfied()?.unwrap();
    let names = cs.constraint_names().unwrap();
    println!("unsatisfied @{}: {}", idx, names[idx]);
}
```

Example output: `unsatisfied @42: root/my_gadget/hash/check_padding/enforce( lc_17 * lc_18 = lc_19 )`

### Debugging Best Practices
- **Small Test Harness**: Create minimal tests with `ConstraintSystemRef::new_ref()`
- **Concrete Witness Values**: Use `assigned_value(var)` to inspect field elements
- **Structured Tracing**: Add `#[tracing::instrument(target = "r1cs", skip(cs, ...))]` to functions
- **Unit Test Gadgets**: Test each gadget in isolation with known inputs
- **Property-Based Testing**: Use randomized inputs to find edge cases
- **In-Circuit Assertions**: Add `assert_eq!` checks during development

### Performance Monitoring
- Use `cs.num_constraints()` and `cs.num_witness_variables()` to track circuit size
- Call `to_matrices()` for deeper structural analysis
- Enable `RUST_LOG=r1cs=trace` for detailed constraint tracing

---

## Logging & Diagnostics (Native/Circuit Sync)

### Log Absorb Events
- Log exactly before every absorb_* call. Emit the preimage encoding (hex) in "audit" builds
- During witness generation, reconstruct the same bytes and log them under the same tag
- Your test harness compares the two logs

### Key Checkpoints
- Log computed aggregators, commitments, derived challenge, and the LHS/RHS of each enforced equality (native side)
- In circuit, expose these as debug witnesses in audit mode if your framework permits

```rust
absorb_public_inputs(
    transcript,
    &input_ciphertext_aggregator,
    &output_ciphertext_aggregator,
    b_vector_commitment,
);

tracing::debug!(
    target: LOG_TARGET,
    "Computed input_ciphertext_aggregator: {:?}",
    input_ciphertext_aggregator
);
```

---

## Transcript and Sponge Usage

### Generic Sponge Pattern
Always use generic type parameters with trait bounds:

```rust
// Native
fn verify_proof<RO>(sponge: &mut RO, proof: &Proof) -> Result<bool, Error>
where
    RO: CryptographicSponge,
{ /* ... */ }

// Circuit
fn verify_proof_gadget<ROVar>(sponge: &mut ROVar, proof_var: &ProofVar) -> Result<Boolean<F>, SynthesisError>
where
    ROVar: CryptographicSpongeVar<F, PoseidonSponge<F>>,
{ /* ... */ }
```

Never hardcode concrete types like `PoseidonSponge<Fr>`.

### Curve Absorption
Use traits from `crates/legit_poker_crypto/src/curve_absorb.rs`:
- Native: implement `CurveAbsorb` trait
- Circuit: implement `CurveAbsorbGadget` trait

---

## Common Pitfalls & How to Avoid Them

- **Assigned but not constrained** -> Always accompany every witness computation with the constraint that forces its value
- **Field confusion (Fr vs Fp)** -> Use bits or non-native vars; never "reinterpret cast"
- **Secret-dependent branches** -> Replace with boolean selects and gate both branches
- **Unsafe division** -> Replace `a/b` with `a * inv(b)` plus a non-zero check gadget
- **Point equality via host ==** -> Use gadget equality constraints

---

## PR & Release Checklists

### PR Checklist
- [ ] No Fr values allocated as FpVar. Scalars are bits or non-native
- [ ] All bits/limbs have boolean/range constraints
- [ ] All equalities are enforced in-circuit (no host comparisons)
- [ ] Transcript encoding documented and used identically in both backends
- [ ] Negative tests cover each enforced relation
- [ ] Constraint counts recorded and compared

### Release Checklist
- [ ] Circuit/key versions bumped and domain-separated
- [ ] Proving/verifying keys re-generated if circuit changed (Groth16)
- [ ] Public input surface area minimized; digests used where possible
