# TickMath Path Explosion Analysis Report

## Executive Summary

This report analyzes the path explosion problem encountered when using symbolic execution (Halmos) on Uniswap V4's
`TickMath` library and documents the solution implemented in `TickMathSimplified.sol`. The original implementation's
bit-manipulation approach creates exponential path explosion during symbolic execution, making formal verification
infeasible. The simplified version uses linear approximation to reduce complexity from O(2^n) to O(1) paths.

---

## 1. The Original TickMath Implementation

### 1.1 Purpose

The `TickMath` library converts between:

- **Ticks**: Discrete price points (int24 values)
- **Sqrt Prices**: Square root of the price ratio in Q64.96 fixed-point format (uint160)

The mathematical relationship is:

$$\text{sqrtPriceX96} = \sqrt{1.0001^{\text{tick}}} \times 2^{96}$$

### 1.2 Implementation Strategy

Located at `lib/v4-core/src/libraries/TickMath.sol`, the `getSqrtPriceAtTick` function uses **bit decomposition** to
compute the price:

```solidity
function getSqrtPriceAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
  unchecked {
    uint256 absTick;
    assembly ("memory-safe") {
      tick := signextend(2, tick)
      let mask := sar(255, tick)
      absTick := xor(mask, add(mask, tick))
    }

    if (absTick > uint256(int256(MAX_TICK))) InvalidTick.selector.revertWith(tick);

    uint256 price;
    assembly ("memory-safe") {
      price := xor(shl(128, 1), mul(xor(shl(128, 1), 0xfffcb933bd6fad37aa2d162d1a594001), and(absTick, 0x1)))
    }
    if (absTick & 0x2 != 0) price = (price * 0xfff97272373d413259a46990580e213a) >> 128;
    if (absTick & 0x4 != 0) price = (price * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
    if (absTick & 0x8 != 0) price = (price * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
    if (absTick & 0x10 != 0) price = (price * 0xffcb9843d60f6159c9db58835c926644) >> 128;
    if (absTick & 0x20 != 0) price = (price * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
    if (absTick & 0x40 != 0) price = (price * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
    if (absTick & 0x80 != 0) price = (price * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
    if (absTick & 0x100 != 0) price = (price * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
    if (absTick & 0x200 != 0) price = (price * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
    if (absTick & 0x400 != 0) price = (price * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
    if (absTick & 0x800 != 0) price = (price * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
    if (absTick & 0x1000 != 0) price = (price * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
    if (absTick & 0x2000 != 0) price = (price * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
    if (absTick & 0x4000 != 0) price = (price * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
    if (absTick & 0x8000 != 0) price = (price * 0x31be135f97d08fd981231505542fcfa6) >> 128;
    if (absTick & 0x10000 != 0) price = (price * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
    if (absTick & 0x20000 != 0) price = (price * 0x5d6af8dedb81196699c329225ee604) >> 128;
    if (absTick & 0x40000 != 0) price = (price * 0x2216e584f5fa1ea926041bedfe98) >> 128;
    if (absTick & 0x80000 != 0) price = (price * 0x48a170391f7dc42444e8fa2) >> 128;

    assembly ("memory-safe") {
      if sgt(tick, 0) {
        price := div(not(0), price)
      }
      sqrtPriceX96 := shr(32, add(price, sub(shl(32, 1), 1)))
    }
  }
}
```

### 1.3 Algorithm Explanation

The algorithm exploits binary decomposition:

$$1.0001^{\text{absTick}} = \prod_{i=0}^{19} \left(1.0001^{2^i}\right)^{b_i}$$

where $b_i \in \{0, 1\}$ are the bits of `absTick`.

Each constant represents $\frac{1}{\sqrt{1.0001^{2^i}}}$ in Q128.128 format:

- `0xfffcb933bd6fad37aa2d162d1a594001` = $\frac{1}{\sqrt{1.0001^{2^0}}}$
- `0xfff97272373d413259a46990580e213a` = $\frac{1}{\sqrt{1.0001^{2^1}}}$
- ...and so on for 20 bit positions

---

## 2. The Path Explosion Problem

### 2.1 Why TickMath Causes Path Explosion

**Path explosion** occurs in symbolic execution when conditional branches create an exponential number of execution
paths that must be explored independently.

For a symbolic variable with `n` conditional branches:

- **Worst case paths**: $2^n$
- **Halmos execution time**: $O(2^n)$

When `tick` is a **symbolic variable** (unknown at analysis time), each bit check creates a branch:

```solidity
if (absTick & 0x1 != 0) price = (price * 0xfffcb933bd6fad37aa2d162d1a594001) >> 128;
if (absTick & 0x2 != 0) price = (price * 0xfff97272373d413259a46990580e213a) >> 128;
// ... 18 more bit checks
```

**Number of paths**: $2^{20} = 1,048,576$ paths

Each path represents a different combination of bits being set/unset, and Halmos must:

1. Fork execution at each branch
2. Maintain separate state for each path
3. Solve constraints for each path

### 2.2 Mathematical Representation of Path Explosion

Let $P(n)$ be the number of execution paths after $n$ conditional branches on symbolic variables:

$$P(n) = 2^n$$

For TickMath with 20 bit checks:

$$P(20) = 2^{20} = 1{,}048{,}576 \text{ paths}$$

The symbolic execution must maintain constraints for each path:

$$\text{Path}_k: \bigwedge_{i=0}^{19} \text{bit}_i = b_{k,i}, \quad k \in [0, 2^{20})$$

where $b_{k,i}$ is the value of bit $i$ in path $k$.

### 2.3 Where This is Called

The TickMath functions are called extensively throughout the pool operations:

**In `halmos/mocks/PoolManagerMockSimplified.sol`:**

- Line 149: `tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);`
- Lines 214-215, 224, 227, 236-237: Multiple calls in `modifyLiquidity`
- Line 361: `pool.slot0.tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96Next);`

**In `halmos/mocks/PoolManagerMock.sol`:**

- Line 248: `tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);`
- Lines 681-682, 691, 694, 706-707: Multiple calls in liquidity operations
- Line 862: `step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);`
- Line 942: `result.tick = TickMath.getTickAtSqrtPrice(result.sqrtPriceX96);`

**Critical Impact**: Swap operations call `getSqrtPriceAtTick` during each tick crossing, and when `tick` values are
symbolic (as they are in formal verification), this creates multiplicative path explosion across the entire swap logic.

### 2.4 Concrete Example of Path Explosion

Consider a simple Halmos test:

```solidity
function check_swap(int24 tickInput) public {
  // tickInput is symbolic
  uint160 price = TickMath.getSqrtPriceAtTick(tickInput);
  // ... rest of swap logic
}
```

**Without simplification:**

- 20 conditional branches → $2^{20}$ paths
- If swap crosses 5 ticks → $2^{20 \times 5} = 2^{100}$ total paths (infeasible)

**With simplification:**

- 3 conditional branches (tick == 0, tick > 0, tick < 0) → 3 paths
- If swap crosses 5 ticks → $3^5 = 243$ paths (feasible)

---

## 3. The TickMathSimplified Solution

### 3.1 Implementation Overview

Located at `halmos/mocks/TickMathSimplified.sol:54-80`, the simplified version uses **piecewise linear approximation**:

```solidity
function getSqrtPriceAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
  // Validate tick is in range
  if (tick < MIN_TICK || tick > MAX_TICK) revert InvalidTick(tick);

  unchecked {
    if (tick == 0) {
      return SQRT_PRICE_AT_TICK_0;
    } else if (tick > 0) {
      // Linear interpolation for positive ticks
      uint256 ratio = (uint256(uint24(tick)) * (MAX_SQRT_PRICE - SQRT_PRICE_AT_TICK_0)) / uint24(MAX_TICK);
      sqrtPriceX96 = uint160(SQRT_PRICE_AT_TICK_0 + ratio);
    } else {
      // Linear interpolation for negative ticks
      uint256 ratio = (uint256(uint24(-tick)) * (SQRT_PRICE_AT_TICK_0 - MIN_SQRT_PRICE)) / uint24(-MIN_TICK);
      sqrtPriceX96 = uint160(SQRT_PRICE_AT_TICK_0 - ratio);
    }
  }
}
```

### 3.2 Mathematical Formulation

The simplified version uses **linear interpolation** between known boundary points:

#### For positive ticks ($\text{tick} > 0$):

$$\text{sqrtPriceX96} = P_0 + \frac{\text{tick}}{T_{\max}} \times (P_{\max} - P_0)$$

where:

- $P_0 = 79228162514264337593543950336$ (price at tick 0)
- $P_{\max} = 1461446703485210103287273052203988822378723970342$ (price at MAX_TICK)
- $T_{\max} = 887272$ (MAX_TICK)

#### For negative ticks ($\text{tick} < 0$):

$$\text{sqrtPriceX96} = P_0 - \frac{|\text{tick}|}{|T_{\min}|} \times (P_0 - P_{\min})$$

where:

- $P_{\min} = 4295128739$ (price at MIN_TICK)
- $T_{\min} = -887272$ (MIN_TICK)

#### Inverse function (getTickAtSqrtPrice):

For $\text{sqrtPriceX96} > P_0$:

$$\text{tick} = \left\lfloor \frac{(\text{sqrtPriceX96} - P_0) \times T_{\max}}{P_{\max} - P_0} \right\rfloor$$

For $\text{sqrtPriceX96} < P_0$:

$$\text{tick} = -\left\lfloor \frac{(P_0 - \text{sqrtPriceX96}) \times |T_{\min}|}{P_0 - P_{\min}} \right\rfloor$$

### 3.3 Path Complexity Analysis

**Original TickMath:** $$\text{Paths} = 2^{20} = 1{,}048{,}576$$

**Simplified TickMath:** $$\text{Paths} = 3 \text{ (one for each branch: tick = 0, tick > 0, tick < 0)}$$

**Improvement factor:** $$\frac{2^{20}}{3} \approx 349{,}525\times \text{ reduction}$$

### 3.4 Trade-offs

#### Advantages:

1. **Dramatic path reduction**: $O(2^{20}) \rightarrow O(1)$
2. **Enables formal verification**: Makes Halmos analysis tractable
3. **Simple to understand**: Linear interpolation is intuitive
4. **Preserves boundary behavior**: Correct at MIN_TICK, 0, and MAX_TICK

#### Disadvantages:

1. **Not mathematically accurate**: Linear approximation of an exponential function
2. **Cannot be used in production**: Price calculations will be incorrect
3. **Limited to formal verification**: Only suitable for symbolic execution testing

### 3.5 Error Bounds

The true relationship is exponential:

$$\text{sqrtPriceX96}_{\text{true}} = \sqrt{1.0001^{\text{tick}}} \times 2^{96}$$

The approximation is linear:

$$\text{sqrtPriceX96}_{\text{approx}} \approx P_0 + k \times \text{tick}$$

Maximum relative error occurs at mid-range ticks where the exponential curve deviates most from the linear
approximation. For a tick range of [-887272, 887272], the error can be significant:

$$\epsilon(\text{tick}) = \left| \frac{\text{sqrtPriceX96}_{\text{true}} - \text{sqrtPriceX96}_{\text{approx}}}{\text{sqrtPriceX96}_{\text{true}}} \right|$$

This error makes the approximation unsuitable for production but acceptable for formal verification where we're testing
logical properties rather than precise arithmetic.

---

## 4. Comparison Summary

| Aspect                  | Original TickMath           | TickMathSimplified        |
| ----------------------- | --------------------------- | ------------------------- |
| **Algorithm**           | Bit decomposition           | Linear interpolation      |
| **Accuracy**            | Mathematically exact        | Approximate               |
| **Path Count**          | $2^{20} = 1{,}048{,}576$    | 3                         |
| **Symbolic Execution**  | Infeasible (path explosion) | Tractable                 |
| **Production Use**      | ✅ Yes                      | ❌ No                     |
| **Formal Verification** | ❌ No (too complex)         | ✅ Yes                    |
| **Gas Cost**            | ~20 conditional branches    | 2-3 arithmetic operations |
| **Constants Required**  | 20 precomputed values       | 3 boundary values         |

---

## 5. Conclusion

The `TickMathSimplified` mock demonstrates a critical technique in formal verification: **strategic simplification to
avoid path explosion**. By replacing the exponentially-complex bit decomposition with linear interpolation, the number
of execution paths is reduced from over 1 million to just 3, making symbolic execution with Halmos feasible.

This approach trades mathematical accuracy for verification tractability—a reasonable compromise when the goal is to
verify logical properties (e.g., no invariant violations, correct state transitions) rather than precise numerical
behavior.

The simplified implementation enables formal verification of critical perpetual futures logic in `PerpManager` and
related contracts, which would otherwise be impossible due to the state space explosion caused by the original TickMath
implementation.

### Key Takeaway

**Path explosion is the primary enemy of symbolic execution.** When a symbolic variable flows through multiple
conditional branches, the number of paths grows exponentially ($2^n$). Strategic simplification of complex arithmetic
(like TickMath's bit decomposition) into simpler approximations (like linear interpolation) is essential for making
formal verification practical on real-world DeFi protocols.

---

## References

- Original TickMath: `lib/v4-core/src/libraries/TickMath.sol`
- Simplified TickMath: `halmos/mocks/TickMathSimplified.sol`
- Usage locations: `halmos/mocks/PoolManagerMock.sol`, `halmos/mocks/PoolManagerMockSimplified.sol`
- Halmos documentation: https://github.com/a16z/halmos
