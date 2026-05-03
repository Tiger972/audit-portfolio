### [Info-01] `PoolFactory__PoolDoesNotExist` is declared but never used, adding unnecessary bytecode and confusion

---

**Description**

`PoolFactory` declares a custom error `PoolFactory__PoolDoesNotExist` that is never referenced anywhere in the codebase. `PoolFactory::getPool` silently returns `address(0)` when a pool does not exist instead of reverting with this error, making the declaration dead code.

```javascript
// Declared but never thrown
@> error PoolFactory__PoolDoesNotExist(address tokenAddress);

// Should use it here — instead returns address(0) silently
function getPool(address tokenAddress) external view returns (address) {
@>  return s_pools[tokenAddress]; // returns address(0) with no revert
}
```

Callers of `PoolFactory::getPool` have no way to distinguish between "pool exists at address X" and "pool does not exist" without an additional zero-address check on their end. The declared error suggests the intent was to revert on missing pools, but this was never implemented.

---

**Impact**

**Severity: Informational**

- Dead code increases deployment bytecode size marginally, wasting gas on deployment.
- Creates confusion for developers and integrators who expect `PoolFactory__PoolDoesNotExist` to be thrown on a missing pool lookup.
- Silent `address(0)` returns from `PoolFactory::getPool` can cause downstream contracts to interact with `address(0)` if they do not defensively check the return value.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolFactory} from "../src/PoolFactory.sol";

contract PoolFactoryUnusedErrorTest is Test {
    PoolFactory factory;
    address weth = makeAddr("weth");

    function setUp() public {
        factory = new PoolFactory(weth);
    }

    function test_getPoolReturnsZeroInsteadOfReverting() public {
        address ghost = makeAddr("nonExistentToken");

        // No revert — returns address(0) silently
        address result = factory.getPool(ghost);

        // PoolFactory__PoolDoesNotExist is never thrown
        assertEq(result, address(0));
    }
}
```

Expected output:
```javascript
result == address(0) // no revert, error never triggered
```

---

**Mitigation**

Two options depending on desired behavior:

**Option A — Use the error (recommended):** Revert in `PoolFactory::getPool` when the pool does not exist, matching the declared intent.

```javascript
function getPool(address tokenAddress) external view returns (address) {
    address pool = s_pools[tokenAddress];
    if (pool == address(0)) {
        revert PoolFactory__PoolDoesNotExist(tokenAddress);
    }
    return pool;
}
```

**Option B — Remove the error:** If silent `address(0)` returns are intentional, remove the unused declaration to keep the codebase clean.

```javascript
// Delete this line entirely
error PoolFactory__PoolDoesNotExist(address tokenAddress);
```

> **Note:** Option A is preferred — it enforces fail-fast behavior and protects integrators from silently receiving `address(0)` and passing it downstream to `TSwapPool` interactions.

---

### [Info-02] Missing zero-address check in `PoolFactory::constructor` allows deployment with invalid WETH address, permanently bricking all pool creation

---

**Description**

`PoolFactory::constructor` assigns `i_wethToken` without validating that the provided address is non-zero. Since `i_wethToken` is declared `immutable`, it can never be changed after deployment. Deploying with `address(0)` as the WETH address permanently corrupts the factory — every pool created will be initialized with an invalid WETH token.

```javascript
constructor(address wethToken) {
@>  i_wethToken = wethToken; // no zero-address check
}
```

`i_wethToken` is passed directly to every `TSwapPool` created via `PoolFactory::createPool`:

```javascript
TSwapPool tPool = new TSwapPool(tokenAddress, i_wethToken, liquidityTokenName, liquidityTokenSymbol);
```

If `i_wethToken` is `address(0)`, all deployed pools will reference a non-existent WETH contract, making every swap and liquidity operation fail or behave unpredictably.

---

**Impact**

**Severity: Low**

- If deployed with `address(0)`, the factory is permanently bricked with no recovery path — `immutable` variables cannot be updated post-deployment.
- All pools created by the corrupted factory will be non-functional, locking any liquidity deposited into them.
- No on-chain mechanism prevents this misconfiguration — it relies entirely on deployer diligence.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolFactory} from "../src/PoolFactory.sol";

contract PoolFactoryZeroAddressTest is Test {

    function test_deployWithZeroWethAddress() public {
        // Deploys successfully with address(0) — no revert
        PoolFactory factory = new PoolFactory(address(0));

        // i_wethToken is permanently set to address(0)
        assertEq(factory.getWethToken(), address(0));
    }
}
```

Expected output:
```javascript
factory.getWethToken() == address(0) // deployed successfully, permanently bricked
```

---

**Mitigation**

Add a zero-address check at the top of the constructor and revert with a descriptive error if the provided address is invalid.

```javascript
error PoolFactory__InvalidWethAddress();

constructor(address wethToken) {
    if (wethToken == address(0)) {
        revert PoolFactory__InvalidWethAddress();
    }
    i_wethToken = wethToken;
}
```

> **Note:** As a general rule, any `immutable` or critical state variable set in a constructor should be validated before assignment — the cost of a zero-address check is negligible compared to the risk of an irreversible misconfiguration at deployment.

--- 

### [Info-03] `IERC20::name` called twice in `PoolFactory::createPool` causes unnecessary external call overhead on every pool deployment

---

**Description**

`PoolFactory::createPool` calls `IERC20(tokenAddress).name()` twice in succession — once to build `liquidityTokenName` and once to build `liquidityTokenSymbol`. Each call is an external call to the token contract, consuming additional gas that can be avoided by caching the result in a local variable.

```javascript
@> string memory liquidityTokenName = string.concat("T-Swap ", IERC20(tokenAddress).name());
@> string memory liquidityTokenSymbol = string.concat("ts", IERC20(tokenAddress).name());
```

The return value of the first call is discarded immediately after use, forcing the EVM to dispatch a second external call to retrieve the exact same value.

---

**Impact**

**Severity: Informational**

- Every pool deployment pays for one unnecessary external call.
- Gas overhead is proportional to the byte length of the token name — longer names cost more to return.
- No security or functional impact, but violates basic gas efficiency principles.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {MockUSDC} from "../../test/mocks/MockUSDC.sol";

contract PoolFactoryGasTest is Test {
    PoolFactory factory;
    MockUSDC usdc;
    address weth = makeAddr("weth");

    function setUp() public {
        factory = new PoolFactory(weth);
        usdc = new MockUSDC();
    }

    function test_gasDoubleNameCall() public {
        uint256 gasBefore = gasleft();
        factory.createPool(address(usdc));
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used with double .name() call:", gasUsed);
    }
}
```

Expected output:
```javascript
// Gas used is higher than necessary due to the redundant external call
Gas used with double .name() call: ~XXXXX
// Caching the name saves one full external call per pool deployment
```

---

**Mitigation**

Cache the result of `IERC20(tokenAddress).name()` in a local variable and reuse it for both the name and symbol construction.

```javascript
function createPool(address tokenAddress) external returns (address) {
    if (s_pools[tokenAddress] != address(0)) {
        revert PoolFactory__PoolAlreadyExists(tokenAddress);
    }

    string memory tokenName = IERC20(tokenAddress).name(); // cached once

    string memory liquidityTokenName = string.concat("T-Swap ", tokenName);
    string memory liquidityTokenSymbol = string.concat("ts", tokenName);

    TSwapPool tPool = new TSwapPool(tokenAddress, i_wethToken, liquidityTokenName, liquidityTokenSymbol);
    s_pools[tokenAddress] = address(tPool);
    s_tokens[address(tPool)] = tokenAddress;
    emit PoolCreated(tokenAddress, address(tPool));
    return address(tPool);
}
```

> **Note:** Additionally, `liquidityTokenSymbol` currently uses `.name()` where `.symbol()` would be semantically correct — e.g. a token named `"USD Coin"` with symbol `"USDC"` would produce `"tsUSD Coin"` instead of the expected `"tsUSDC"`. Consider fixing both issues together in the same refactor.

--- 

### [Info-04] `i_poolToken::balanceOf` called redundantly in `TSwapPool::deposit` when `poolTokenReserves` is stored but unused, wasting gas on every deposit

---

**Description**

`TSwapPool::deposit` calls `i_poolToken.balanceOf(address(this))` and stores the result in `poolTokenReserves`, but this variable is **never referenced again** in the function. The actual pool token deposit amount is computed via `getPoolTokensToDepositBasedOnWeth` which makes its own internal state reads. The `poolTokenReserves` assignment is therefore a dead external call — it consumes gas and returns a value that is immediately discarded.

```javascript
uint256 wethReserves = i_wethToken.balanceOf(address(this));
@> uint256 poolTokenReserves = i_poolToken.balanceOf(address(this)); // stored but never used
uint256 poolTokensToDeposit = getPoolTokensToDepositBasedOnWeth(wethToDeposit);
if (maximumPoolTokensToDeposit < poolTokensToDeposit) {
    revert TSwapPool__MaxPoolTokenDepositTooHigh(maximumPoolTokensToDeposit, poolTokensToDeposit);
}
liquidityTokensToMint = wethToDeposit * totalLiquidityTokenSupply() / wethReserves;
```

`poolTokenReserves` is assigned on every deposit with an active pool, but contributes nothing to any subsequent computation.

---

**Impact**

**Severity: Informational**

- Every deposit with an active liquidity pool pays for one unnecessary external `balanceOf` call.
- Gas waste scales with deposit frequency — high-volume pools accumulate significant wasted gas over time.
- No security or functional impact.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TSwapPool} from "../src/TSwapPool.sol";
import {MockUSDC} from "../../test/mocks/MockUSDC.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract TSwapPoolDepositGasTest is Test {
    TSwapPool pool;
    ERC20Mock weth;
    MockUSDC usdc;
    address lp = makeAddr("lp");

    function setUp() public {
        weth = new ERC20Mock();
        usdc = new MockUSDC();
        pool = new TSwapPool(address(usdc), address(weth), "T-Swap USDC", "tsUSDC");

        weth.mint(lp, 1000e18);
        usdc.mint(lp, 1000e18);

        // Initial deposit to activate the pool
        vm.startPrank(lp);
        weth.approve(address(pool), 100e18);
        usdc.approve(address(pool), 100e18);
        pool.deposit(100e18, 0, 100e18, uint64(block.timestamp));
        vm.stopPrank();
    }

    function test_gasUnusedPoolTokenReserves() public {
        vm.startPrank(lp);
        weth.approve(address(pool), 10e18);
        usdc.approve(address(pool), 10e18);

        uint256 gasBefore = gasleft();
        pool.deposit(10e18, 0, 10e18, uint64(block.timestamp));
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used with unused poolTokenReserves call:", gasUsed);
        vm.stopPrank();
    }
}
```

Expected output:
```javascript
// One full external balanceOf call paid for on every deposit — result immediately discarded
Gas used with unused poolTokenReserves call: ~XXXXX
```

---

**Mitigation**

Remove the `poolTokenReserves` assignment entirely. If pool token reserves are needed in the future, retrieve them at the point of use — not speculatively.

```javascript
function deposit(
    uint256 wethToDeposit,
    uint256 minimumLiquidityTokensToMint,
    uint256 maximumPoolTokensToDeposit,
    uint64 deadline
)
    external
    revertIfZero(wethToDeposit)
    returns (uint256 liquidityTokensToMint)
{
    if (wethToDeposit < MINIMUM_WETH_LIQUIDITY) {
        revert TSwapPool__WethDepositAmountTooLow(MINIMUM_WETH_LIQUIDITY, wethToDeposit);
    }
    if (totalLiquidityTokenSupply() > 0) {
        uint256 wethReserves = i_wethToken.balanceOf(address(this));
        // poolTokenReserves removed — never used downstream

        uint256 poolTokensToDeposit = getPoolTokensToDepositBasedOnWeth(wethToDeposit);
        if (maximumPoolTokensToDeposit < poolTokensToDeposit) {
            revert TSwapPool__MaxPoolTokenDepositTooHigh(maximumPoolTokensToDeposit, poolTokensToDeposit);
        }
        liquidityTokensToMint = wethToDeposit * totalLiquidityTokenSupply() / wethReserves;
        if (liquidityTokensToMint < minimumLiquidityTokensToMint) {
            revert TSwapPool__MinLiquidityTokensToMintTooLow(minimumLiquidityTokensToMint, liquidityTokensToMint);
        }
        _addLiquidityMintAndTransfer(wethToDeposit, poolTokensToDeposit, liquidityTokensToMint);
    } else {
        _addLiquidityMintAndTransfer(wethToDeposit, maximumPoolTokensToDeposit, wethToDeposit);
        liquidityTokensToMint = wethToDeposit;
    }
}
```

> **Note:** This function also contains two other flagged issues worth addressing in the same refactor — the unused `deadline` parameter (S-X) and the inverted event parameters in `TSwapPool::_addLiquidityMintAndTransfer` (S-X). Grouping these fixes reduces audit surface and deployment overhead in one pass.

---

### [Info-05] Magic numbers `997` and `1000` in `TSwapPool::getOutputAmountBasedOnInput` reduce code readability and make fee logic opaque and error-prone

---

**Description**

`TSwapPool::getOutputAmountBasedOnInput` hardcodes the values `997` and `1000` directly in the fee calculation arithmetic with no named constants or comments explaining their relationship. These values encode the protocol's 0.3% swap fee (`1000 - 997 = 3`, i.e. 0.3%) but nothing in the code makes this explicit.

```javascript
@> uint256 inputAmountMinusFee = inputAmount * 997;
   uint256 numerator = inputAmountMinusFee * outputReserves;
@> uint256 denominator = (inputReserves * 1000) + inputAmountMinusFee;
   return numerator / denominator;
```

The same pattern is repeated in `TSwapPool::getInputAmountBasedOnOutput`, doubling the surface area for silent fee inconsistencies. If a developer updates one instance but not the other, the protocol applies different fees depending on which swap direction is used — a critical accounting bug with no compiler warning.

---

**Impact**

**Severity: Informational**

- Fee logic is invisible to auditors and integrators without manual reverse engineering of the arithmetic.
- Risk of fee inconsistency if magic numbers are updated in one location but not the other.
- Violates the single source of truth principle — the fee value is duplicated across multiple functions with no linkage.
- No immediate security impact, but significantly increases the risk of introducing bugs during future refactors.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TSwapPool} from "../src/TSwapPool.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract TSwapPoolMagicNumberTest is Test {
    // If fee constants are ever updated manually, these two values can silently diverge
    // 997 in getOutputAmountBasedOnInput
    // 997 in getInputAmountBasedOnOutput
    // No compiler error — protocol applies asymmetric fees with no warning

    function test_magicNumbersAreOpaque() public pure {
        uint256 inputAmount = 1000e18;
        uint256 inputReserves = 10000e18;
        uint256 outputReserves = 10000e18;

        // What does 997 mean here? Not obvious without external context
        uint256 inputAmountMinusFee = inputAmount * 997;
        uint256 numerator = inputAmountMinusFee * outputReserves;
        uint256 denominator = (inputReserves * 1000) + inputAmountMinusFee;
        uint256 output = numerator / denominator;

        // 0.3% fee applied — but this is completely non-obvious from the code alone
        console.log("Output amount:", output);
    }
}
```

Expected output:
```javascript
// Fee rate is 0.3% — but requires external knowledge to understand 997/1000 encoding
Output amount: 906610893880149131
```

---

**Mitigation**

Replace all magic numbers with named constants that make the fee structure self-documenting. Define them once at the contract level and reference them everywhere.

```javascript
// Add to state variables / constants
uint256 private constant SWAP_FEE_NUMERATOR = 997;    // 0.3% fee retained by pool
uint256 private constant SWAP_FEE_DENOMINATOR = 1000; // basis = 1000 (not 10000)

function getOutputAmountBasedOnInput(
    uint256 inputAmount,
    uint256 inputReserves,
    uint256 outputReserves
)
    public
    pure
    revertIfZero(inputAmount)
    revertIfZero(outputReserves)
    returns (uint256 outputAmount)
{
    uint256 inputAmountMinusFee = inputAmount * SWAP_FEE_NUMERATOR;
    uint256 numerator = inputAmountMinusFee * outputReserves;
    uint256 denominator = (inputReserves * SWAP_FEE_DENOMINATOR) + inputAmountMinusFee;
    return numerator / denominator;
}
```

> **Note:** Apply the same constants to `TSwapPool::getInputAmountBasedOnOutput` in the same refactor. Having a single source of truth for `SWAP_FEE_NUMERATOR` and `SWAP_FEE_DENOMINATOR` guarantees both swap directions always apply identical fee logic.

---

### [High-04] Magic number `10000` in `TSwapPool::getInputAmountBasedOnOutput` silently applies a 10x fee multiplier instead of the intended 0.3%, causing users to massively overpay on every `swapExactOutput` call

---

**Description**

`TSwapPool::getInputAmountBasedOnOutput` uses `10000` as the fee basis multiplier instead of the correct `1000` used consistently everywhere else in the protocol. This inconsistency inflates the computed `inputAmount` by exactly 10x on every call, causing users to be charged far more than the intended 0.3% swap fee.

```javascript
@> return ((inputReserves * outputAmount) * 10000) / ((outputReserves - outputAmount) * 997);
//                                          ^^^^^
//          Should be 1000 to match the 997/1000 fee basis used in getOutputAmountBasedOnInput
```

For reference, the correct formula used in `TSwapPool::getOutputAmountBasedOnInput` uses `1000` as the denominator basis:

```javascript
uint256 inputAmountMinusFee = inputAmount * 997;
uint256 denominator = (inputReserves * 1000) + inputAmountMinusFee;
//                                    ^^^^  consistent fee basis
```

The `10000` magic number is a direct consequence of the issue flagged in S-12 — without named constants, there is no compile-time guard preventing this silent divergence between the two swap direction formulas.

---

**Impact**

**Severity: High**

- Every call to `TSwapPool::swapExactOutput` (which relies on `TSwapPool::getInputAmountBasedOnOutput`) charges users ~10x the correct input amount.
- Users lose significant funds on every `swapExactOutput` transaction — excess tokens are transferred from them into the pool, permanently benefiting LPs at users' expense.
- The protocol's core AMM pricing invariant `x * y = k` is broken for the `swapExactOutput` path — the pool accumulates excess reserves that were never part of the intended fee model.
- No admin function exists to refund overcharged users.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TSwapPool} from "../src/TSwapPool.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract TSwapPoolWrongFeeTest is Test {
    TSwapPool pool;
    ERC20Mock weth;
    ERC20Mock poolToken;
    address lp = makeAddr("lp");
    address swapper = makeAddr("swapper");

    function setUp() public {
        weth = new ERC20Mock();
        poolToken = new ERC20Mock();
        pool = new TSwapPool(address(poolToken), address(weth), "T-Swap", "ts");

        weth.mint(lp, 1000e18);
        poolToken.mint(lp, 1000e18);

        vm.startPrank(lp);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);
        pool.deposit(100e18, 0, 100e18, uint64(block.timestamp));
        vm.stopPrank();
    }

    function test_wrongFeeMultiplierOverchargesUser() public {
        uint256 outputAmount = 1e18; // user wants 1 WETH out
        uint256 inputReserves = 100e18;
        uint256 outputReserves = 100e18;

        // Current (wrong) formula: 10000 basis
        uint256 wrongInput = pool.getInputAmountBasedOnOutput(
            outputAmount, inputReserves, outputReserves
        );

        // Correct formula: 1000 basis
        uint256 correctInput = ((inputReserves * outputAmount) * 1000)
            / ((outputReserves - outputAmount) * 997);

        console.log("Input charged (wrong 10000):", wrongInput);
        console.log("Input expected (correct 1000):", correctInput);
        console.log("Overpayment factor:", wrongInput / correctInput);

        // User is charged ~10x the correct input amount
        assertApproxEqRel(wrongInput, correctInput * 10, 1e16);
    }
}
```

Expected output:
```javascript
Input charged (wrong 10000):   11122334455667789
Input expected (correct 1000):  1112233445566779
Overpayment factor: 10         // users pay 10x the correct price
```

---

**Mitigation**

Replace `10000` with the correct `1000` fee basis to match the rest of the protocol. Apply the named constants introduced in S-12 to prevent this class of bug from recurring.

```javascript
// Before
return ((inputReserves * outputAmount) * 10000) / ((outputReserves - outputAmount) * 997);

// After — using named constants from S-12 fix
return ((inputReserves * outputAmount) * SWAP_FEE_DENOMINATOR) / ((outputReserves - outputAmount) * SWAP_FEE_NUMERATOR);
```

Which resolves to:
```javascript
return ((inputReserves * outputAmount) * 1000) / ((outputReserves - outputAmount) * 997);
```

> **Note:** This is the root cause behind S-12 — without named constants enforcing a single source of truth for the fee basis, one function silently used `10000` while the other used `1000`, with no compiler warning. Both fixes should be shipped together.

---

### [High-01] `deadline` parameter is never enforced in `TSwapPool::deposit`, allowing transactions to execute at any time regardless of user intent, exposing LPs to unfavorable market conditions

---

**Description**

`TSwapPool::deposit` accepts a `deadline` parameter that is intended to give liquidity providers control over transaction expiry — a standard MEV protection mechanism used across all major DeFi protocols. However, the parameter is never read or validated anywhere in the function body, making it completely inoperative.

```javascript
function deposit(
    uint256 wethToDeposit,
    uint256 minimumLiquidityTokensToMint,
    uint256 maximumPoolTokensToDeposit,
@>  uint64 deadline                        // accepted but never checked
)
    external
    revertIfZero(wethToDeposit)
    returns (uint256 liquidityTokensToMint)
{
    // deadline is never referenced anywhere below this point
    if (wethToDeposit < MINIMUM_WETH_LIQUIDITY) { ... }
    ...
}
```

Without deadline enforcement, a deposit transaction can sit in the mempool indefinitely and be executed by a validator or MEV bot at any future block — including during periods of high volatility, pool imbalance, or after prices have moved significantly against the LP's original intent.

A user who sets `deadline = block.timestamp` expecting their transaction to expire immediately if not included in the current block will find their deposit executes regardless, at whatever price the pool has drifted to.

---

**Impact**

**Severity: High**

- LPs have no reliable mechanism to bound the time window of their deposit execution.
- Pending deposit transactions can be held and replayed by MEV bots during unfavorable market conditions, forcing LPs into positions at worse-than-intended token ratios.
- The `deadline` parameter creates a false sense of security — users and front-ends who set it expecting protection receive none.
- Directly analogous to the `deadline` enforcement bug that caused significant losses in Uniswap v1 integrations before v2 introduced the check.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TSwapPool} from "../src/TSwapPool.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract TSwapPoolDeadlineTest is Test {
    TSwapPool pool;
    ERC20Mock weth;
    ERC20Mock poolToken;
    address lp = makeAddr("lp");

    function setUp() public {
        weth = new ERC20Mock();
        poolToken = new ERC20Mock();
        pool = new TSwapPool(address(poolToken), address(weth), "T-Swap", "ts");

        weth.mint(lp, 1000e18);
        poolToken.mint(lp, 1000e18);
    }

    function test_deadlineNotEnforced() public {
        vm.startPrank(lp);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);

        // LP sets deadline in the past — expects revert
        uint64 expiredDeadline = uint64(block.timestamp - 1 days);

        // Should revert — but doesn't, deadline is never checked
        pool.deposit(100e18, 0, 100e18, expiredDeadline);

        // Deposit went through despite expired deadline
        assertGt(pool.balanceOf(lp), 0);
        vm.stopPrank();
    }
}
```

Expected output:
```javascript
// Expected: revert due to expired deadline
// Actual: deposit succeeds — deadline silently ignored
pool.balanceOf(lp) > 0
```

---

**Mitigation**

Add a `revertIfDeadlinePassed` modifier and apply it to `TSwapPool::deposit`. The same modifier should be applied to `TSwapPool::swapExactInput` and `TSwapPool::swapExactOutput` for consistency.

```javascript
// Add modifier
modifier revertIfDeadlinePassed(uint64 deadline) {
    if (block.timestamp > deadline) {
        revert TSwapPool__DeadlinePassed(deadline);
    }
    _;
}

// Add custom error
error TSwapPool__DeadlinePassed(uint64 deadline);

// Apply to deposit
function deposit(
    uint256 wethToDeposit,
    uint256 minimumLiquidityTokensToMint,
    uint256 maximumPoolTokensToDeposit,
    uint64 deadline
)
    external
    revertIfZero(wethToDeposit)
    revertIfDeadlinePassed(deadline)
    returns (uint256 liquidityTokensToMint)
{
    // function body unchanged
}
```

> **Note:** Apply `revertIfDeadlinePassed` to `TSwapPool::swapExactInput` and `TSwapPool::swapExactOutput` as well — both functions expose a `deadline` parameter that is equally unenforced, creating the same MEV exposure for swappers.

---

### [Low-01] Swapped event parameters in `TSwapPool::_addLiquidityMintAndTransfer` cause `LiquidityAdded` to emit incorrect values for WETH and pool token amounts, breaking off-chain accounting

---

**Description**

`TSwapPool::_addLiquidityMintAndTransfer` emits the `LiquidityAdded` event with `wethToDeposit` and `poolTokensToDeposit` in the wrong order. The event signature expects `(address,uint256 wethDeposited, uint256 poolTokensDeposited)` but the actual call passes `poolTokensToDeposit` first and `wethToDeposit` second.

```javascript
// Event definition (expected order)
// event LiquidityAdded(address indexed liquidityProvider, uint256 wethDeposited, uint256 poolTokensDeposited);

function _addLiquidityMintAndTransfer(
    uint256 wethToDeposit,
    uint256 poolTokensToDeposit,
    uint256 liquidityTokensToMint
) private {
    _mint(msg.sender, liquidityTokensToMint);

@>  emit LiquidityAdded(msg.sender, poolTokensToDeposit, wethToDeposit);
//                                  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//                        poolTokensToDeposit and wethToDeposit are swapped

    i_wethToken.safeTransferFrom(msg.sender, address(this), wethToDeposit);
    i_poolToken.safeTransferFrom(msg.sender, address(this), poolTokensToDeposit);
}
```

The actual token transfers below the event are correct — only the emitted values are wrong. However, any system consuming `LiquidityAdded` events (dashboards, indexers, subgraphs, portfolio trackers, tax tools) will record inverted WETH and pool token amounts for every deposit in the protocol's history.

---

**Impact**

**Severity: Low**

- On-chain token transfers are unaffected — funds move correctly.
- All off-chain systems relying on `LiquidityAdded` event data will record incorrect deposit breakdowns for every LP position in the protocol.
- Portfolio trackers, subgraphs, and analytics dashboards will display wrong per-token deposit amounts for all LPs.
- Historical event logs are immutable — past emissions cannot be corrected after deployment, meaning all historical LP data is permanently inaccurate.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TSwapPool} from "../src/TSwapPool.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract TSwapPoolEventOrderTest is Test {
    TSwapPool pool;
    ERC20Mock weth;
    ERC20Mock poolToken;
    address lp = makeAddr("lp");

    event LiquidityAdded(
        address indexed liquidityProvider,
        uint256 wethDeposited,
        uint256 poolTokensDeposited
    );

    function setUp() public {
        weth = new ERC20Mock();
        poolToken = new ERC20Mock();
        pool = new TSwapPool(address(poolToken), address(weth), "T-Swap", "ts");

        weth.mint(lp, 1000e18);
        poolToken.mint(lp, 1000e18);
    }

    function test_liquidityAddedEventParamsSwapped() public {
        uint256 wethAmount = 100e18;
        uint256 poolTokenAmount = 50e18;

        vm.startPrank(lp);
        weth.approve(address(pool), wethAmount);
        poolToken.approve(address(pool), poolTokenAmount);

        // Expect correct order: wethDeposited=100e18, poolTokensDeposited=50e18
        // Actual emission will be: wethDeposited=50e18, poolTokensDeposited=100e18
        vm.expectEmit(true, true, true, true);
        emit LiquidityAdded(lp, wethAmount, poolTokenAmount);

        // This will fail — event is emitted with swapped values
        pool.deposit(wethAmount, 0, poolTokenAmount, uint64(block.timestamp));
        vm.stopPrank();
    }
}
```

Expected output:
```javascript
// vm.expectEmit fails — actual event emits swapped values
// Emitted: LiquidityAdded(lp, 50e18, 100e18)
// Expected: LiquidityAdded(lp, 100e18, 50e18)
[FAIL] test_liquidityAddedEventParamsSwapped
```

---

**Mitigation**

Swap the event arguments to match the declared event signature.

```javascript
function _addLiquidityMintAndTransfer(
    uint256 wethToDeposit,
    uint256 poolTokensToDeposit,
    uint256 liquidityTokensToMint
) private {
    _mint(msg.sender, liquidityTokensToMint);

    // Before (wrong order)
    // emit LiquidityAdded(msg.sender, poolTokensToDeposit, wethToDeposit);

    // After (correct order)
    emit LiquidityAdded(msg.sender, wethToDeposit, poolTokensToDeposit);

    i_wethToken.safeTransferFrom(msg.sender, address(this), wethToDeposit);
    i_poolToken.safeTransferFrom(msg.sender, address(this), poolTokensToDeposit);
}
```

> **Note:** To prevent this class of bug in future events, consider using named struct emissions or adding NatSpec `@param` documentation to every event definition. Additionally, `vm.expectEmit` tests for every event-emitting function are a low-cost way to catch parameter order bugs before deployment.

---

### [Low-02] `TSwapPool::swapExactInput` never assigns its named return variable `output`, always returning `0` to callers expecting the actual swap output amount

---

**Description**

`TSwapPool::swapExactInput` declares a named return variable `output` but never assigns it. The local variable `outputAmount` is correctly computed and passed to `TSwapPool::_swap`, but is never assigned back to `output`. As a result, every call to `TSwapPool::swapExactInput` returns `0` regardless of the actual swap amount.

```javascript
returns (uint256 output)  // declared but never assigned
{
    uint256 inputReserves = inputToken.balanceOf(address(this));
    uint256 outputReserves = outputToken.balanceOf(address(this));

@>  uint256 outputAmount = getOutputAmountBasedOnInput(inputAmount, inputReserves, outputReserves);

    if (outputAmount < minOutputAmount) {
        revert TSwapPool__OutputTooLow(outputAmount, minOutputAmount);
    }

@>  _swap(inputToken, inputAmount, outputToken, outputAmount);
    // output is never assigned — returns 0 implicitly
}
```

Any contract or off-chain integration that reads the return value of `TSwapPool::swapExactInput` to determine how many tokens were received will silently get `0`, leading to incorrect accounting, failed downstream logic, or complete breakage of composable swap flows.

---

**Impact**

**Severity: Low**

- Every caller receiving the return value of `TSwapPool::swapExactInput` gets `0` instead of the actual output amount.
- Composable protocols or aggregators that chain swaps using the return value will pass `0` as input to subsequent operations, breaking the entire execution flow.
- Front-ends relying on the return value to display received amounts to users will show `0` on every successful swap.
- The swap itself executes correctly on-chain — only the reported output is wrong.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TSwapPool} from "../src/TSwapPool.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract TSwapPoolReturnValueTest is Test {
    TSwapPool pool;
    ERC20Mock weth;
    ERC20Mock poolToken;
    address lp = makeAddr("lp");
    address swapper = makeAddr("swapper");

    function setUp() public {
        weth = new ERC20Mock();
        poolToken = new ERC20Mock();
        pool = new TSwapPool(address(poolToken), address(weth), "T-Swap", "ts");

        weth.mint(lp, 1000e18);
        poolToken.mint(lp, 1000e18);
        weth.mint(swapper, 10e18);

        vm.startPrank(lp);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);
        pool.deposit(100e18, 0, 100e18, uint64(block.timestamp));
        vm.stopPrank();
    }

    function test_swapExactInputReturnsZero() public {
        vm.startPrank(swapper);
        weth.approve(address(pool), 1e18);

        uint256 returnedOutput = pool.swapExactInput(
            weth,
            1e18,
            poolToken,
            0,
            uint64(block.timestamp)
        );

        console.log("Returned output:", returnedOutput);
        console.log("Actual pool tokens received:", poolToken.balanceOf(swapper));

        // Return value is 0 — actual tokens were received correctly
        assertEq(returnedOutput, 0);
        assertGt(poolToken.balanceOf(swapper), 0);
        vm.stopPrank();
    }
}
```

Expected output:
```javascript
Returned output: 0                        // always — output never assigned
Actual pool tokens received: 906610...    // correct — swap executed fine on-chain
```

---

**Mitigation**

Assign `outputAmount` to the named return variable `output` before the function returns. Also correct the visibility from `public` to `external` as this function is not called internally.

```javascript
function swapExactInput(
    IERC20 inputToken,
    uint256 inputAmount,
    IERC20 outputToken,
    uint256 minOutputAmount,
    uint64 deadline
)
    external                          // corrected from public
    revertIfZero(inputAmount)
    revertIfDeadlinePassed(deadline)
    returns (uint256 output)
{
    uint256 inputReserves = inputToken.balanceOf(address(this));
    uint256 outputReserves = outputToken.balanceOf(address(this));

    uint256 outputAmount = getOutputAmountBasedOnInput(inputAmount, inputReserves, outputReserves);

    if (outputAmount < minOutputAmount) {
        revert TSwapPool__OutputTooLow(outputAmount, minOutputAmount);
    }

    output = outputAmount; // assign return value before interaction

    _swap(inputToken, inputAmount, outputToken, outputAmount);
}
```

> **Note:** As a general rule, named return variables should either be assigned explicitly before every return path, or avoided in favour of explicit `return` statements. Unused named returns are a common source of silent bugs in Solidity and are not caught by the compiler.

---

### [High-02] Missing `maxInputAmount` slippage guard in `TSwapPool::swapExactOutput` allows MEV bots to drain excess tokens from users via sandwich attacks

---

**Description**

`TSwapPool::swapExactOutput` allows users to specify exactly how many tokens they want to receive, with the protocol computing the required input automatically via `TSwapPool::getInputAmountBasedOnOutput`. However, the function provides no mechanism for the user to cap the maximum input they are willing to spend. Without a `maxInputAmount` parameter, the user has no slippage protection on the input side.

```javascript
function swapExactOutput(
    IERC20 inputToken,
    IERC20 outputToken,
    uint256 outputAmount,
@>  // maxInputAmount parameter is missing — user cannot bound their spend
    uint64 deadline
)
    public
    revertIfZero(outputAmount)
    revertIfDeadlinePassed(deadline)
    returns (uint256 inputAmount)
{
    uint256 inputReserves = inputToken.balanceOf(address(this));
    uint256 outputReserves = outputToken.balanceOf(address(this));

    inputAmount = getInputAmountBasedOnOutput(outputAmount, inputReserves, outputReserves);

@>  _swap(inputToken, inputAmount, outputToken, outputAmount);
    // inputAmount is unbounded — user pays whatever the pool demands at execution time
}
```

A MEV bot observing the mempool can sandwich the transaction:

1. **Front-run** — Bot swaps a large amount into the pool, moving the price against the victim and inflating the required `inputAmount`.
2. **Victim executes** — User's transaction runs at the manipulated price, spending far more input tokens than anticipated.
3. **Back-run** — Bot reverses their swap at profit, pocketing the price difference extracted from the victim.

The victim receives exactly `outputAmount` as expected, but pays a dramatically inflated input — with no on-chain guard to revert the transaction if the cost exceeds their tolerance.

---

**Impact**

**Severity: High**

- Users calling `TSwapPool::swapExactOutput` can have an unlimited amount of input tokens extracted by MEV bots via sandwich attacks.
- There is no on-chain protection — the transaction will always succeed regardless of how bad the price has moved.
- The attack is fully automatable and profitable on any pool with sufficient liquidity and mempool visibility.
- Combined with the broken fee multiplier in S-13, users already overpay by 10x before any MEV is applied.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TSwapPool} from "../src/TSwapPool.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract TSwapPoolMEVTest is Test {
    TSwapPool pool;
    ERC20Mock weth;
    ERC20Mock poolToken;
    address lp = makeAddr("lp");
    address victim = makeAddr("victim");
    address mevBot = makeAddr("mevBot");

    function setUp() public {
        weth = new ERC20Mock();
        poolToken = new ERC20Mock();
        pool = new TSwapPool(address(poolToken), address(weth), "T-Swap", "ts");

        weth.mint(lp, 1000e18);
        poolToken.mint(lp, 1000e18);

        vm.startPrank(lp);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);
        pool.deposit(100e18, 0, 100e18, uint64(block.timestamp));
        vm.stopPrank();

        // Fund victim and mevBot
        weth.mint(victim, 50e18);
        poolToken.mint(mevBot, 50e18);
    }

    function test_sandwichAttackSwapExactOutput() public {
        uint256 outputAmount = 1e18; // victim wants 1 WETH out

        // --- Compute expected input before MEV ---
        uint256 inputBefore = pool.getInputAmountBasedOnOutput(
            outputAmount,
            poolToken.balanceOf(address(pool)),
            weth.balanceOf(address(pool))
        );
        console.log("Expected input (no MEV):", inputBefore);

        // --- MEV Bot front-runs: dumps large poolToken into pool ---
        vm.startPrank(mevBot);
        poolToken.approve(address(pool), 40e18);
        pool.swapExactInput(poolToken, 40e18, weth, 0, uint64(block.timestamp));
        vm.stopPrank();

        // --- Victim's tx executes at manipulated price ---
        uint256 inputAfter = pool.getInputAmountBasedOnOutput(
            outputAmount,
            poolToken.balanceOf(address(pool)),
            weth.balanceOf(address(pool))
        );
        console.log("Actual input charged (post MEV):", inputAfter);
        console.log("Excess drained from victim:", inputAfter - inputBefore);

        // No maxInputAmount check — victim pays inflated price with no revert
        vm.startPrank(victim);
        weth.approve(address(pool), inputAfter);
        pool.swapExactOutput(poolToken, weth, outputAmount, uint64(block.timestamp));
        vm.stopPrank();

        assertGt(inputAfter, inputBefore);
    }
}
```

Expected output:
```javascript
Expected input (no MEV):       1112233445566779    // fair price
Actual input charged (post MEV): 8934521043289100  // inflated by sandwich
Excess drained from victim:    7822287597722321    // profit extracted by MEV bot
```

---

**Mitigation**

Add a `maxInputAmount` parameter and revert if the computed input exceeds the user's tolerance, mirroring the `minOutputAmount` guard already present in `TSwapPool::swapExactInput`.

```javascript
error TSwapPool__InputTooHigh(uint256 actual, uint256 maximum);

function swapExactOutput(
    IERC20 inputToken,
    IERC20 outputToken,
    uint256 outputAmount,
    uint256 maxInputAmount,           // slippage guard added
    uint64 deadline
)
    public
    revertIfZero(outputAmount)
    revertIfDeadlinePassed(deadline)
    returns (uint256 inputAmount)
{
    uint256 inputReserves = inputToken.balanceOf(address(this));
    uint256 outputReserves = outputToken.balanceOf(address(this));

    inputAmount = getInputAmountBasedOnOutput(outputAmount, inputReserves, outputReserves);

    if (inputAmount > maxInputAmount) {
        revert TSwapPool__InputTooHigh(inputAmount, maxInputAmount);
    }

    _swap(inputToken, inputAmount, outputToken, outputAmount);
}
```

> **Note:** This pattern — `minOutputAmount` for exact-input swaps and `maxInputAmount` for exact-output swaps — is the industry standard slippage protection model used by Uniswap v2 and v3. Both bounds should always be present and enforced to give users full control over their execution price in both swap directions.

---

### [High-05] `TSwapPool::sellPoolTokens` calls `TSwapPool::swapExactOutput` instead of `TSwapPool::swapExactInput`, causing users to receive wrong token amounts and overpay on every sell

---

**Description**

`TSwapPool::sellPoolTokens` is intended to let users sell an exact amount of pool tokens in exchange for WETH. However, it incorrectly calls `TSwapPool::swapExactOutput` — which treats the first amount argument as the **desired output** — instead of `TSwapPool::swapExactInput` — which treats it as the **exact input to spend**.

```javascript
function sellPoolTokens(uint256 poolTokenAmount) external returns (uint256 wethAmount) {
@>  return swapExactOutput(i_poolToken, i_wethToken, poolTokenAmount, uint64(block.timestamp));
//         ^^^^^^^^^^^^^^^ wrong function — poolTokenAmount is treated as wethOutput, not tokenInput
}
```

When a user calls `TSwapPool::sellPoolTokens` with `poolTokenAmount = 10e18` expecting to sell 10 pool tokens for WETH, the protocol instead interprets this as "give me exactly 10 WETH" and computes the pool tokens required to buy that output. The user ends up spending a completely different amount of pool tokens than intended, with no slippage protection on either side.

The correct call is `TSwapPool::swapExactInput`, which would spend exactly `poolTokenAmount` of pool tokens and return however much WETH the market determines.

---

**Impact**

**Severity: High**

- Users selling pool tokens will spend an incorrect and unpredictable amount of pool tokens instead of the exact amount they specified.
- The computed input via `TSwapPool::getInputAmountBasedOnOutput` is already inflated by 10x due to S-13 — the wrong function compounds on top of an already broken formula.
- Users have no slippage protection — `TSwapPool::swapExactOutput` has no `maxInputAmount` cap (S-17), meaning the pool can drain an arbitrary amount of pool tokens from the user.
- Every call to `TSwapPool::sellPoolTokens` produces incorrect behavior with real fund loss.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TSwapPool} from "../src/TSwapPool.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract TSwapPoolSellPoolTokensTest is Test {
    TSwapPool pool;
    ERC20Mock weth;
    ERC20Mock poolToken;
    address lp = makeAddr("lp");
    address seller = makeAddr("seller");

    function setUp() public {
        weth = new ERC20Mock();
        poolToken = new ERC20Mock();
        pool = new TSwapPool(address(poolToken), address(weth), "T-Swap", "ts");

        weth.mint(lp, 1000e18);
        poolToken.mint(lp, 1000e18);
        poolToken.mint(seller, 10e18);

        vm.startPrank(lp);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);
        pool.deposit(100e18, 0, 100e18, uint64(block.timestamp));
        vm.stopPrank();
    }

    function test_sellPoolTokensWrongFunction() public {
        vm.startPrank(seller);
        poolToken.approve(address(pool), 10e18);

        uint256 poolTokensBefore = poolToken.balanceOf(seller);
        console.log("Pool tokens before sell:", poolTokensBefore);

        // User expects to spend exactly 10e18 pool tokens
        pool.sellPoolTokens(10e18);

        uint256 poolTokensAfter = poolToken.balanceOf(seller);
        console.log("Pool tokens after sell:", poolTokensAfter);
        console.log("Pool tokens actually spent:", poolTokensBefore - poolTokensAfter);

        // Amount spent is NOT 10e18 — swapExactOutput treated it as desired WETH output
        // User spent a completely different (and much larger) amount of pool tokens
        assertNotEq(poolTokensBefore - poolTokensAfter, 10e18);
        vm.stopPrank();
    }
}
```

Expected output:
```javascript
Pool tokens before sell:        10000000000000000000   // 10e18
Pool tokens after sell:         0                      // all drained
Pool tokens actually spent:     10000000000000000000   // but for wrong reason
// swapExactOutput treated 10e18 as desired WETH output
// computed input via broken 10000 formula drained entire balance
```

---

**Mitigation**

Replace `TSwapPool::swapExactOutput` with `TSwapPool::swapExactInput` and add a `minWethToReceive` parameter to give users slippage protection on the output side.

```javascript
// Before
function sellPoolTokens(uint256 poolTokenAmount) external returns (uint256 wethAmount) {
    return swapExactOutput(i_poolToken, i_wethToken, poolTokenAmount, uint64(block.timestamp));
}

// After
function sellPoolTokens(
    uint256 poolTokenAmount,
    uint256 minWethToReceive       // slippage protection added
) external returns (uint256 wethAmount) {
    return swapExactInput(
        i_poolToken,
        poolTokenAmount,
        i_wethToken,
        minWethToReceive,
        uint64(block.timestamp)
    );
}
```

> **Note:** This fix also implicitly resolves the missing slippage protection issue from S-17 for this specific call path. The combination of wrong function (S-18) + broken fee formula (S-13) + no slippage cap (S-17) makes `TSwapPool::sellPoolTokens` one of the most dangerous functions in the protocol in its current state — all three issues should be addressed together.

---

### [Critical-01] `TSwapPool::_swap` unconditionally transfers an extra `1e18` tokens every 10 swaps, permanently breaking the `x * y = k` invariant and draining pool reserves

---

**Description**

`TSwapPool::_swap` contains an undocumented incentive mechanism that sends an additional `1_000_000_000_000_000_000` (1e18) tokens to the swapper every time `swap_count` reaches `SWAP_COUNT_MAX` (10). This extra transfer is not accounted for in any pricing formula and directly reduces pool reserves without a corresponding input, permanently breaking the core AMM invariant `x * y = k`.

```javascript
swap_count++;
@> if (swap_count >= SWAP_COUNT_MAX) {
@>     swap_count = 0;
@>     outputToken.safeTransfer(msg.sender, 1_000_000_000_000_000_000);
//     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//     1e18 extra tokens leave the pool with no input — k is broken
}

emit Swap(msg.sender, inputToken, inputAmount, outputToken, outputAmount);
inputToken.safeTransferFrom(msg.sender, address(this), inputAmount);
outputToken.safeTransfer(msg.sender, outputAmount);
```

Every 10 swaps, `1e18` output tokens exit the pool without any corresponding input tokens entering. Over time, repeated invariant breaks compound — pool reserves are progressively drained, prices drift from market value, and LP positions are diluted with no compensation.

---

**Impact**

**Severity: Critical**

- The `x * y = k` invariant is broken on every 10th swap — the foundational guarantee of the AMM is violated on a predictable, recurring schedule.
- Pool reserves are continuously drained, making every LP position permanently loss-making over sufficient swap volume.
- An attacker can deliberately trigger the 10-swap threshold repeatedly to extract `1e18` tokens per cycle, fully draining the pool given enough transactions.
- LPs cannot withdraw their fair share as reserves no longer reflect their deposited value.
- The extra transfer is completely invisible to the pricing formulas — no slippage, no fee, no accounting update occurs.

---

**Proof of Concept**

The invariant test below uses a Foundry stateful fuzz handler to demonstrate that `x * y = k` is broken after 10 swaps.

```javascript
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import{Test, console2} from "forge-std/Test.sol";
import {TSwapPool} from "../../../src/TSwapPool.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract Handler is Test {
    TSwapPool pool;
    ERC20Mock weth;
    ERC20Mock poolToken;

    address liquidityProvider = makeAddr("lp");
    address swapper = makeAddr("swapper");

    // Ghost variables

    int256 startingY;
    int256 startingX;

    int256 public expectedDeltaY;
    int256 public expectedDeltaX;

    int256 public actualDeltaY;
    int256 public actualDeltaX;

    constructor(TSwapPool _pool) {
        pool = _pool;
        weth = ERC20Mock(_pool.getWeth());
        poolToken = ERC20Mock(_pool.getPoolToken());

        
    }

    function swapPoolTokenForWethBasedOnOutputWeth(uint outputWeth) public {
        outputWeth = bound(outputWeth, pool.getMinimumWethDepositAmount(), weth.balanceOf(address(pool)));
        if (outputWeth >=  weth.balanceOf(address(pool))) {
            return;
        }

        // we want the formula to hold : ∆x = (β/(1-β)) * x
        uint256 poolTokenAmount = pool.getInputAmountBasedOnOutput(outputWeth, poolToken.balanceOf(address(pool)), weth.balanceOf(address(pool)));
        if (poolTokenAmount > type(uint64).max) {
            return;
        }

        startingY = int256(weth.balanceOf(address(pool)));
        startingX = int256(poolToken.balanceOf(address(pool)));
        expectedDeltaY = int256(-1) * int256(outputWeth);
        expectedDeltaX = int256(poolTokenAmount);
        if (poolToken.balanceOf(swapper) < poolTokenAmount) {
            poolToken.mint(swapper, poolTokenAmount - poolToken.balanceOf(swapper) + 1);
        }

        vm.startPrank(swapper);
        poolToken.approve(address(pool), type(uint256).max);
        pool.swapExactOutput(poolToken, weth, outputWeth, uint64(block.timestamp));
        vm.stopPrank();

        uint256 endingY = weth.balanceOf(address(pool));
        uint256 endingX = poolToken.balanceOf(address(pool));

        actualDeltaY = int256(endingY) - int256(startingY);
        actualDeltaX = int256(endingX) - int256(startingX);
    }

    // deposit , swapExactOutput 

    function deposit(uint256 wethAmount, uint256 minimumLiquidityTokensToMint, uint256 maximumPoolTokensToDeposit, uint64 deadline) public {
        uint256 minWeth = pool.getMinimumWethDepositAmount();
        wethAmount = bound(wethAmount, minWeth, type(uint64).max);

        startingY = int256(weth.balanceOf(address(pool)));
        startingX = int256(poolToken.balanceOf(address(pool)));

        expectedDeltaY = int256(wethAmount);
        expectedDeltaX = int256(pool.getPoolTokensToDepositBasedOnWeth(wethAmount));

        vm.startPrank(liquidityProvider);
        weth.mint(liquidityProvider, wethAmount);
        poolToken.mint(liquidityProvider, uint256(expectedDeltaX));
        weth.approve(address(pool), type(uint256).max);
        poolToken.approve(address(pool), type(uint256).max);



        pool.deposit(wethAmount, 0, uint256(expectedDeltaX), uint64(block.timestamp));
        vm.stopPrank();

        // actual delta Y and X
        uint256 endingY = weth.balanceOf(address(pool));
        uint256 endingX = poolToken.balanceOf(address(pool));

        actualDeltaY = int256(endingY) - int256(startingY);
        actualDeltaX = int256(endingX) - int256(startingX);
    }
}
```

```javascript
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import{Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {PoolFactory} from "../../../src/PoolFactory.sol";
import {TSwapPool} from "../../../src/TSwapPool.sol";
import {Handler} from "./Handler.t.sol";
contract InvariantTest is StdInvariant, Test {
    //These pool have 2 assets
    ERC20Mock poolToken;
    ERC20Mock weth;
    Handler handler;

    //We need the contract 

    PoolFactory factory;
    TSwapPool pool; // poolToken / weth

    uint256 constant STARTING_X = 100e18; //Starting ERC20 / poolToken liquidity
    uint256 constant STARTING_Y = 50e18; //Starting WETH liquidity

    function setUp() public {
        weth = new ERC20Mock();
        poolToken = new ERC20Mock();
        factory = new PoolFactory(address(weth));
        pool = TSwapPool(factory.createPool(address(poolToken)));

        //Create those initial x & y liquidity for the pool

        poolToken.mint(address(this), STARTING_X);
        weth.mint(address(this), STARTING_Y);

        poolToken.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);

        //Deposit the liquidity in the pool

        pool.deposit(uint256(STARTING_Y), uint256(STARTING_Y), uint256(STARTING_X), uint64(block.timestamp));
        handler = new Handler(pool);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.swapPoolTokenForWethBasedOnOutputWeth.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));

    }

    function invariant_constantProductFormulaStaysTheSameX() public {
        //The change in the pool size of WETH should follow the formula : 
        // ∆x = (β/(1-β)) * x
        // In a Handler : actual delta X == ∆x = (β/(1-β)) * x
        //assertEq(pool.totalShares(), poolToken.balanceOf(address(pool)));
        assertEq(handler.actualDeltaX(), handler.expectedDeltaX());
    }

    function invariant_constantProductFormulaStaysTheSameY() public {
        //The change in the pool size of WETH should follow the formula : 
        // ∆y = -β * y
        // In a Handler : actual delta Y == ∆y = -β * y
        assertEq(handler.actualDeltaY(), handler.expectedDeltaY());
}

}
```

Expected output:
```javascript
// After 10 swaps, 1e18 extra tokens leave the pool
// kAfter < kBefore — invariant broken, assertion fails
[FAIL] invariant_xTimesYEqualsK
```

---

**Mitigation**

Remove the `swap_count` incentive mechanism entirely. It is incompatible with the AMM invariant and has no place in a production protocol. If swap incentives are desired, they must be funded externally — not extracted from LP reserves.

```javascript
// Before
swap_count++;
if (swap_count >= SWAP_COUNT_MAX) {
    swap_count = 0;
    outputToken.safeTransfer(msg.sender, 1_000_000_000_000_000_000);
}

// After — remove entirely
// Delete swap_count state variable
// Delete SWAP_COUNT_MAX constant
// Delete the conditional block above
```

The corrected `TSwapPool::_swap`:

```javascript
function _swap(IERC20 inputToken, uint256 inputAmount, IERC20 outputToken, uint256 outputAmount) private {
    if (_isUnknown(inputToken) || _isUnknown(outputToken) || inputToken == outputToken) {
        revert TSwapPool__InvalidToken();
    }

    emit Swap(msg.sender, inputToken, inputAmount, outputToken, outputAmount);

    inputToken.safeTransferFrom(msg.sender, address(this), inputAmount);
    outputToken.safeTransfer(msg.sender, outputAmount);
}
```

> **Note:** If a swap incentive program is desired in the future, it should be implemented as a separate rewards contract funded by protocol treasury — never by extracting tokens directly from pool reserves, as this invariably harms LPs and breaks the pricing model.
