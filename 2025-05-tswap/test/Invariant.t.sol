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

