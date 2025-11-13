# Halmos path-tracing mini-lab

## Setup (once)

- Pull the commit with debug statements: `39b69d5c9df8f56ce1412a6ecd7aa046fd91c982`
- When running Halmos, pass: `--print-step`
- For the early parts, **comment out `setUp()`** so it doesn’t introduce extra path constraints.

### Example run command

```bash
halmos run \
  --print-step \
  --function check_totalPriceBuggy \
  --src ./src \
  --test ./test
```

(Adjust paths/flags to your repo layout.)

---

## Part 0 — verify debug wiring

**Goal:** confirm the added Halmos debug statements are visible.

1. Build & run with `--print-step`.
2. Ensure no `setUp()` is executed yet.

**You should see:** Halmos step prints in the console as paths branch/merge.

---

## Part 1 — minimal branching

```solidity
function check_totalPriceBuggy(uint32 quantity) public view {
  // even this generates two paths
}
```

**What to do**

1. Run Halmos on the empty function (still with `--print-step`, `setUp()` commented out).
2. Inspect the printed steps and path count.

**Record**

- **Q:** Which instruction generates the two paths? (Note file/line/opcode if possible.)
- **A:** `JUMPI` instruction at PC `0x364`. Branch condition is
  `Concat(0x0, Extract(0x1f, 0x0, p_quantity_uint32_74c2a10_00)) == p_quantity_uint32_74c2a10_00`

---

## Part 2 — effect of `assert`

```solidity
function check_totalPriceBuggy(uint32 quantity) public view {
  assert(quantity == 0);
}
```

**What to do**

1. Run again and compare path conditions vs Part 1.
2. Note the branch where `quantity == 0` holds vs fails.

**Record**

- **Q:** How does `assert` affect the path condition?

---

## Part 3 — `vm.assume` + `assert`

```solidity
function check_totalPriceBuggy(uint32 quantity) public view {
  vm.assume(quantity > 0);
  assert(quantity == 0);
}
```

**What to do**

1. Run and check feasibility of paths post-assume.
2. Observe any UNSAT paths reported due to conflicting constraints.

**Record**

- **Q:** How does `vm.assume` affect the path condition?

---

## Part 5 — concrete value, trivial assert

```solidity
function check_totalPriceBuggy(uint32 /*quantity*/) public view {
  uint256 val = 0;
  assert(val == 0);
}
```

**What to do**

1. Run and confirm whether any symbolic branching remains.

**Record**

- **Q:** How does a concrete `val` affect the path condition?

---

## Part 6 — “printing” + stopping the interpreter

_Add to storage:_

```solidity
uint32 DEBUG_SLOT2;
string public message;
```

_Test body:_

```solidity
function check_totalPriceBuggy(uint32 /*quantity*/) public view {
  uint256 val = 6;
  assembly {
    sstore(DEBUG_SLOT2.slot, val)
    // note: writing a Solidity string directly via sstore is not a full string write;
    // dynamic strings use length @ slot, bytes at keccak(slot). keep this in mind.
    sstore(message.slot, "aaaae5")
    stop()
  }
  assert(val == 0);
}
```

**What to do**

1. Run and confirm you can observe changes to the specified storage slots in the trace.
2. Use `stop()` to halt exactly where you want inspection.

**Hints**

- **Print a number:** write to a known slot (e.g., `DEBUG_SLOT2`) and read it from the interpreter or via a dump.
- **Print a string:** dynamic storage layout = `message.slot` holds (length << 1) | 1, bytes at
  `keccak256(message.slot)`. For quick “printing,” consider emitting a custom event or `revert(...)` with encoded data.
- **Stop at a line:** `assembly { stop() }` or `revert(<tag>)` to halt with a recognizable marker.

**Record**

- **Q:** How can I print a variable’s value in the interpreter?
- **Q:** How can I print a string in the interpreter?
- **Q:** How can I stop the interpreter at a particular line?

---

## Part 7 — re-enable `setUp()`

```solidity
function check_totalPriceBuggy() public view {}
```

**What to do**

1. Uncomment `setUp()` and run.
2. Use your print/stop tactics to trace where execution flows in `setUp()`.

**Record**

- **Q:** Which **symbolic conditions** are generated in `setUp()` and what is the corresponding source line(s)? (Capture
  each `assume/assert/require/branch` you see and map it to code.)

---

## Part 8 — bring back `_createPerp`

```solidity
function check_totalPriceBuggy() public view {
  perpId1 = _createPerp(creator);
}
```

**What to do**

1. Run and trace into `_createPerp()` path conditions.
2. Note constraints originating from dependencies (e.g., Ownable/Beacon, TimeWeightedAvg, etc.).

**Record**

- **Q:** Which **symbolic conditions** are generated in `_createPerp()` and what source code induces them? _Hint:_ you
  should see conditions related to Ownable/Beacon/TimeWeightedAvg flows.

---

## Quick tips

- Prefer **small, single-change commits** per part so diffs are obvious.
- When isolating a condition, add a temporary `stop()` right after it.
- For “printing,” three practical routes:
  1. **Storage write** to a known slot (numeric),
  2. **Event** emit (cleanest for human-readable),
  3. **Revert with data** (air-quotes “printf via revert”).
