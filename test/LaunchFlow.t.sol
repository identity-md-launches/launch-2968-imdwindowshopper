// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDwindowshopper} from "../src/IMDwindowshopper.sol";

/// @dev Test-only CREATE2 creator, distinct from the caller initiating deployment.
contract Create2TokenFactoryFixture {
    function deploy(bytes32 salt) external returns (IMDwindowshopper) {
        return new IMDwindowshopper{salt: salt}();
    }
}

contract LaunchFlowTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    function test_create2AndLaunchTransfersDeliverExactAmounts() public {
        Create2TokenFactoryFixture factory = new Create2TokenFactoryFixture();
        bytes32 salt = keccak256("local launch fixture");
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(factory), salt, keccak256(type(IMDwindowshopper).creationCode)
                        )
                    )
                )
            )
        );
        IMDwindowshopper token = factory.deploy(salt);
        assertEq(address(token), predicted);
        assertEq(token.balanceOf(address(factory)), SUPPLY);

        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("poolManager");
        address remainderRecipient = makeAddr("remainderRecipient");
        address claimant = makeAddr("claimant");
        address trader = makeAddr("trader");
        uint256 swarm = SUPPLY / 10;
        uint256 pool = SUPPLY * 7 / 10;
        uint256 remainder = SUPPLY - swarm - pool;

        vm.startPrank(address(factory));
        assertTrue(token.transfer(distributor, swarm));
        assertTrue(token.transfer(poolManager, pool));
        assertTrue(token.transfer(remainderRecipient, remainder));
        vm.stopPrank();
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.balanceOf(remainderRecipient), remainder);

        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.balanceOf(claimant), swarm);

        // Token movement in both directions only; this fixture does not implement AMM swaps.
        uint256 traded = 123 ether;
        vm.prank(poolManager);
        assertTrue(token.transfer(trader, traded));
        assertEq(token.balanceOf(trader), traded);
        assertEq(token.balanceOf(poolManager), pool - traded);
        vm.prank(trader);
        assertTrue(token.transfer(poolManager, traded));
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(claimant) + token.balanceOf(poolManager) + token.balanceOf(remainderRecipient), SUPPLY);
    }
}
