// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDwindowshopper} from "../src/IMDwindowshopper.sol";

/// @dev A contract recipient that fails on any call: a token with a recipient hook could not pay it.
contract RevertingRecipientFixture {
    receive() external payable {
        revert("recipient was called");
    }

    fallback() external payable {
        revert("recipient was called");
    }
}

/// @dev Deploys and splits the supply in one call, as one launch transaction does.
contract AtomicLaunchFixture {
    function launch(address distributor, address pool, address remainder, uint256 poolBps)
        external
        returns (IMDwindowshopper token)
    {
        token = new IMDwindowshopper();
        uint256 supply = token.totalSupply();
        uint256 swarm = (supply * 1_000) / 10_000;
        uint256 seeded = (supply * poolBps) / 10_000;
        require(token.transfer(distributor, swarm), "swarm transfer returned false");
        require(token.transfer(pool, seeded), "seed transfer returned false");
        require(token.transfer(remainder, supply - swarm - seeded), "remainder transfer returned false");
    }
}

/// @dev Credits what its balance actually changed by, the way a pool manager settles a currency.
contract BalanceDeltaSettlerFixture {
    function pull(IERC20 token, address from, uint256 amount) external returns (uint256 credited) {
        uint256 reserves = token.balanceOf(address(this));
        require(token.transferFrom(from, address(this), amount), "pull returned false");
        credited = token.balanceOf(address(this)) - reserves;
    }

    function push(IERC20 token, address to, uint256 amount) external returns (uint256 delivered) {
        uint256 reserves = token.balanceOf(to);
        require(token.transfer(to, amount), "push returned false");
        delivered = token.balanceOf(to) - reserves;
    }
}

/// @notice The inputs the base suite does not reach: zero-address callers, which check fires first, the top
/// of the allowance range, malformed calldata, native value, storage touched, and the opcodes a launch refuses.
contract IMDwindowshopperEdgeTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    IMDwindowshopper internal token;
    address internal alice;
    address internal bob;
    address internal spender;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        token = new IMDwindowshopper();
    }

    // ---------------------------------------------------------------- the zero address as caller

    function test_zeroCallerCannotTransferAnyAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(alice, 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(alice, 1);
    }

    function test_zeroCallerCannotApprove() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(spender, 1);
    }

    function test_zeroCallerCannotSpendAnAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(address(0));
        token.transferFrom(address(this), alice, 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(0), 0, 1));
        vm.prank(address(0));
        token.transferFrom(address(this), alice, 1);
    }

    function test_zeroOwnerWithNonZeroValueFailsOnAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(0), alice, 1);
    }

    function test_zeroValueTransferFromToZeroReceiverReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 0);
    }

    // ---------------------------------------------------------------- which check fires first

    function test_allowanceIsCheckedBeforeBalance() public {
        vm.prank(alice);
        token.approve(spender, 1);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 1, 2));
        vm.prank(spender);
        token.transferFrom(alice, bob, 2);
    }

    function test_allowanceIsCheckedBeforeReceiver() public {
        token.approve(spender, 1);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 1, 2));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 2);
    }

    // ---------------------------------------------------------------- the edges of an allowance

    function test_allowanceOneBelowMaximumIsFinite() public {
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), type(uint256).max - 2);
    }

    function test_infiniteAllowanceCannotExceedBalance() public {
        token.approve(spender, type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, SUPPLY + 1);
    }

    function test_infiniteAllowanceSurvivesFullDrainThenFailsOnBalance() public {
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, SUPPLY));
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(address(this)), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
    }

    function test_allowanceReservesNothingAndRevivesWithTheBalance() public {
        token.transfer(alice, 10);
        vm.startPrank(alice);
        token.approve(spender, 10);
        token.transfer(bob, 10);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, spender), 10);

        vm.prank(bob);
        token.transfer(alice, 4);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 4));
        assertEq(token.allowance(alice, spender), 6);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 10);
    }

    function test_selfApprovalPaysForTransferFromOnOwnAccount() public {
        token.approve(address(this), 5);
        assertTrue(token.transferFrom(address(this), alice, 5));
        assertEq(token.allowance(address(this), address(this)), 0);
        assertEq(token.balanceOf(alice), 5);
    }

    function test_spenderMayPayItself() public {
        token.approve(spender, 3);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), spender, 3));
        assertEq(token.balanceOf(spender), 3);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_zeroValueTransferFromLeavesFiniteAllowanceAlone() public {
        token.approve(spender, 7);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 0));
        assertEq(token.allowance(address(this), spender), 7);
    }

    function test_allowanceRunsOneWayOnly() public {
        vm.prank(alice);
        token.approve(bob, 9);
        assertEq(token.allowance(alice, bob), 9);
        assertEq(token.allowance(bob, alice), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(bob, alice, 1);
    }

    function test_spendingAnAllowanceEmitsOnlyTheTransfer() public {
        token.approve(spender, 5);
        vm.recordLogs();
        vm.prank(spender);
        token.transferFrom(address(this), alice, 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
    }

    // ---------------------------------------------------------------- the same call twice, the exact boundary

    function test_wholeBalanceTransferCannotBeRepeated() public {
        assertTrue(token.transfer(alice, SUPPLY));

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, SUPPLY)
        );
        token.transfer(alice, SUPPLY);
    }

    function test_oneWeiAboveTheWholeSupplyReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
    }

    function test_oneWeiHolderCanSendOneButNotTwo() public {
        token.transfer(alice, 1);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1, 2));
        vm.prank(alice);
        token.transfer(bob, 2);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 1));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);
    }

    function test_roundTripRestoresBothBalancesExactly() public {
        token.transfer(alice, 1);
        vm.prank(alice);
        token.transfer(address(this), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_eachDeploymentMintsOnceAndKeepsItsOwnLedger() public {
        IMDwindowshopper second = new IMDwindowshopper();
        assertTrue(address(second) != address(token));
        assertTrue(second.transfer(alice, 11));

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(second.balanceOf(address(this)), SUPPLY - 11);
        assertEq(second.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- the external surface

    /// @dev The ten calls the token declares, each valid from this test. They are the positive control
    /// for the rejection tests below: without it those would pass on a token that rejected everything.
    function _declaredCalls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](10);
        calls[0] = abi.encodeWithSignature("name()");
        calls[1] = abi.encodeWithSignature("symbol()");
        calls[2] = abi.encodeWithSignature("decimals()");
        calls[3] = abi.encodeWithSignature("totalSupply()");
        calls[4] = abi.encodeWithSignature("INITIAL_SUPPLY()");
        calls[5] = abi.encodeWithSignature("balanceOf(address)", address(this));
        calls[6] = abi.encodeWithSignature("allowance(address,address)", address(this), spender);
        calls[7] = abi.encodeWithSignature("transfer(address,uint256)", alice, uint256(0));
        calls[8] = abi.encodeWithSignature("approve(address,uint256)", spender, uint256(0));
        calls[9] = abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), alice, uint256(0));
    }

    function _isDeclaredSelector(bytes4 selector) internal pure returns (bool) {
        return selector == bytes4(keccak256("name()")) || selector == bytes4(keccak256("symbol()"))
            || selector == bytes4(keccak256("decimals()")) || selector == bytes4(keccak256("totalSupply()"))
            || selector == bytes4(keccak256("INITIAL_SUPPLY()")) || selector == bytes4(keccak256("balanceOf(address)"))
            || selector == bytes4(keccak256("allowance(address,address)"))
            || selector == bytes4(keccak256("transfer(address,uint256)"))
            || selector == bytes4(keccak256("approve(address,uint256)"))
            || selector == bytes4(keccak256("transferFrom(address,address,uint256)"));
    }

    function test_everyDeclaredEntrypointAnswers() public {
        bytes[] memory calls = _declaredCalls();
        for (uint256 i; i < calls.length; ++i) {
            bytes4 selector = bytes4(calls[i]);
            assertTrue(_isDeclaredSelector(selector), "selector list and call list disagree");
            (bool ok,) = address(token).call(calls[i]);
            assertTrue(ok, "a declared entrypoint reverted");
        }
    }

    function test_everyEntrypointRejectsNativeValue() public {
        vm.deal(address(this), 1 ether);
        bytes[] memory calls = _declaredCalls();
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call{value: 1}(calls[i]);
            assertFalse(ok, "an entrypoint accepted native value");
        }
        assertEq(address(token).balance, 0);
    }

    function test_constructorRejectsNativeValueButDeploysWithout() public {
        vm.deal(address(this), 1 ether);
        bytes memory code = type(IMDwindowshopper).creationCode;
        address paid;
        address unpaid;
        assembly ("memory-safe") {
            paid := create(1, add(code, 32), mload(code))
            unpaid := create(0, add(code, 32), mload(code))
        }
        assertEq(paid, address(0));
        assertTrue(unpaid != address(0));
        assertEq(IMDwindowshopper(unpaid).balanceOf(address(this)), SUPPLY);
    }

    /// @dev v4's currency transfer accepts only empty returndata or the word 1, so the exact bytes matter.
    function test_mutatingCallsReturnExactlyTheWordTrue() public {
        token.approve(address(this), 1);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSignature("transfer(address,uint256)", alice, uint256(1));
        calls[1] = abi.encodeWithSignature("approve(address,uint256)", spender, uint256(1));
        calls[2] = abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), alice, uint256(1));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory returned) = address(token).call(calls[i]);
            assertTrue(ok);
            assertEq(returned, abi.encode(true));
        }
    }

    function test_truncatedCalldataIsRejected() public {
        bytes4 selector = bytes4(keccak256("transfer(address,uint256)"));
        bytes32 to = bytes32(uint256(uint160(alice)));
        bytes[] memory calls = new bytes[](5);
        calls[0] = hex"a9";
        calls[1] = hex"a9059c";
        calls[2] = abi.encodePacked(selector);
        calls[3] = abi.encodePacked(selector, to);
        calls[4] = abi.encodePacked(selector, to, bytes31(uint248(1)));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok, "truncated calldata was accepted");
        }
        assertEq(token.balanceOf(alice), 0);

        // The same encoding at full length is accepted, so the rejections above are about the length.
        (bool whole,) = address(token).call(abi.encodePacked(selector, to, uint256(1)));
        assertTrue(whole);
        assertEq(token.balanceOf(alice), 1);
    }

    function test_addressArgumentsWithDirtyHighBitsAreRejected() public {
        bytes4 transferSelector = bytes4(keccak256("transfer(address,uint256)"));
        bytes32 clean = bytes32(uint256(uint160(alice)));
        bytes32 dirty = bytes32(uint256(uint160(alice)) | (uint256(1) << 160));
        bytes32 self = bytes32(uint256(uint160(address(this))));
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodePacked(transferSelector, dirty, uint256(1));
        calls[1] = abi.encodePacked(bytes4(keccak256("approve(address,uint256)")), dirty, uint256(1));
        calls[2] = abi.encodePacked(bytes4(keccak256("transferFrom(address,address,uint256)")), self, dirty, uint256(0));
        calls[3] = abi.encodePacked(bytes4(keccak256("balanceOf(address)")), dirty);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok, "a dirty address was accepted");
        }
        assertEq(token.balanceOf(alice), 0);

        (bool accepted,) = address(token).call(abi.encodePacked(transferSelector, clean, uint256(1)));
        assertTrue(accepted);
        assertEq(token.balanceOf(alice), 1);
    }

    function test_contractRecipientIsNeverCalled() public {
        RevertingRecipientFixture recipient = new RevertingRecipientFixture();
        assertTrue(token.transfer(address(recipient), 1 ether));
        token.approve(spender, 1 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(recipient), 1 ether));
        assertEq(token.balanceOf(address(recipient)), 2 ether);
    }

    // ---------------------------------------------------------------- exactly which storage a call writes

    function _balanceSlot(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, uint256(0)));
    }

    function _allowanceSlot(address owner, address allowed) internal pure returns (bytes32) {
        return keccak256(abi.encode(allowed, keccak256(abi.encode(owner, uint256(1)))));
    }

    function _assertWroteExactly(bytes32[] memory expected) internal {
        (, bytes32[] memory writes) = vm.accesses(address(token));
        for (uint256 i; i < writes.length; ++i) {
            assertTrue(_contains(expected, writes[i]), "the call wrote a slot outside the expected set");
        }
        for (uint256 i; i < expected.length; ++i) {
            assertTrue(_contains(writes, expected[i]), "the call did not write an expected slot");
        }
    }

    function _contains(bytes32[] memory slots, bytes32 slot) internal pure returns (bool) {
        for (uint256 i; i < slots.length; ++i) {
            if (slots[i] == slot) return true;
        }
        return false;
    }

    /// @dev Anchors the slot arithmetic above; the write tests below would mean nothing without it.
    function test_storageLayoutIsWhatTheWriteChecksAssume() public {
        token.approve(spender, 77);
        assertEq(vm.load(address(token), _balanceSlot(address(this))), bytes32(SUPPLY));
        assertEq(vm.load(address(token), _allowanceSlot(address(this), spender)), bytes32(uint256(77)));
        assertEq(vm.load(address(token), bytes32(uint256(2))), bytes32(SUPPLY));
    }

    function test_transferWritesOnlyTheTwoBalances() public {
        bytes32[] memory expected = new bytes32[](2);
        expected[0] = _balanceSlot(address(this));
        expected[1] = _balanceSlot(alice);
        vm.record();
        token.transfer(alice, 5);
        _assertWroteExactly(expected);
    }

    function test_approveWritesOnlyTheOneAllowance() public {
        bytes32[] memory expected = new bytes32[](1);
        expected[0] = _allowanceSlot(address(this), spender);
        vm.record();
        token.approve(spender, 5);
        _assertWroteExactly(expected);
    }

    function test_finiteSpendWritesTheAllowanceAndTwoBalances() public {
        token.approve(spender, 5);
        bytes32[] memory expected = new bytes32[](3);
        expected[0] = _allowanceSlot(address(this), spender);
        expected[1] = _balanceSlot(address(this));
        expected[2] = _balanceSlot(alice);
        vm.record();
        vm.prank(spender);
        token.transferFrom(address(this), alice, 5);
        _assertWroteExactly(expected);
    }

    function test_infiniteSpendLeavesTheAllowanceSlotUntouched() public {
        token.approve(spender, type(uint256).max);
        bytes32[] memory expected = new bytes32[](2);
        expected[0] = _balanceSlot(address(this));
        expected[1] = _balanceSlot(alice);
        vm.record();
        vm.prank(spender);
        token.transferFrom(address(this), alice, 5);
        _assertWroteExactly(expected);
    }

    // ---------------------------------------------------------------- what a launch refuses

    /// @dev Reachable code only, read as the launch floor reads it; constants after the code are not
    /// instructions. Stricter than the floor: a plain token has no reason to call anything or create anything.
    function test_reachableRuntimeHasNoCallCreateOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        bool reachable = true;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF0, "CREATE");
                assertTrue(op != 0xF1, "CALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF5, "CREATE2");
                assertTrue(op != 0xFA, "STATICCALL");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    function _assertAtomicLaunch(uint256 poolBps) internal {
        AtomicLaunchFixture factory = new AtomicLaunchFixture();
        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("poolManager");
        address remainder = makeAddr("remainder");

        IMDwindowshopper launched = factory.launch(distributor, poolManager, remainder, poolBps);

        uint256 swarm = SUPPLY / 10;
        uint256 seeded = (SUPPLY * poolBps) / 10_000;
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(distributor), swarm);
        assertEq(launched.balanceOf(poolManager), seeded);
        assertEq(launched.balanceOf(remainder), SUPPLY - swarm - seeded);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_atomicLaunchAtThisJobsEconomics() public {
        _assertAtomicLaunch(7_000);
    }

    /// @dev Nothing left for the remainder: the launch still has to complete, on a zero-value transfer.
    function test_atomicLaunchWithNoRemainder() public {
        _assertAtomicLaunch(9_000);
    }

    function testFuzz_atomicLaunchDeliversEveryShareExactly(uint256 poolBpsSeed) public {
        _assertAtomicLaunch(bound(poolBpsSeed, 0, 9_000));
    }

    function testFuzz_settlementByBalanceDeltaIsExact(uint256 amountSeed) public {
        uint256 amount = bound(amountSeed, 0, SUPPLY);
        BalanceDeltaSettlerFixture settler = new BalanceDeltaSettlerFixture();
        token.approve(address(settler), amount);

        assertEq(settler.pull(IERC20(address(token)), address(this), amount), amount);
        assertEq(settler.push(IERC20(address(token)), alice, amount), amount);
        assertEq(token.balanceOf(address(settler)), 0);
        assertEq(token.allowance(address(this), address(settler)), 0);
    }

    // ---------------------------------------------------------------- fuzzed across the whole range

    function _account(uint256 seed) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("www.account", seed)))));
    }

    function testFuzz_unknownSelectorsRevertEmptyFromAnyCaller(bytes4 selector, bytes calldata tail, uint256 callerSeed)
        public
    {
        while (_isDeclaredSelector(selector)) {
            selector = bytes4(keccak256(abi.encode(selector)));
        }
        bytes memory data = abi.encodePacked(selector, tail);
        if (callerSeed % 2 == 1) vm.prank(_account(callerSeed));
        (bool ok, bytes memory returned) = address(token).call(data);

        assertFalse(ok, "an undeclared selector was accepted");
        assertEq(returned.length, 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_anyHolderMovesExactlyWhatItAskedTo(
        uint256 fromSeed,
        uint256 toSeed,
        uint256 fundedSeed,
        uint256 amountSeed
    ) public {
        address from = _account(fromSeed);
        address to = toSeed % 8 == 0 ? from : _account(toSeed);
        uint256 funded = bound(fundedSeed, 0, SUPPLY);
        uint256 amount = bound(amountSeed, 0, funded);
        token.transfer(from, funded);

        vm.prank(from);
        assertTrue(token.transfer(to, amount));

        if (from == to) {
            assertEq(token.balanceOf(from), funded);
        } else {
            assertEq(token.balanceOf(from), funded - amount);
            assertEq(token.balanceOf(to), amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_allowanceAccountingAcrossTheWholeRange(uint256 approved, uint256 fundedSeed, uint256 amountSeed)
        public
    {
        uint256 funded = bound(fundedSeed, 0, SUPPLY);
        uint256 amount = bound(amountSeed, 0, approved < funded ? approved : funded);
        token.transfer(alice, funded);
        vm.prank(alice);
        token.approve(spender, approved);

        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, amount));

        assertEq(token.allowance(alice, spender), approved == type(uint256).max ? approved : approved - amount);
        assertEq(token.balanceOf(alice), funded - amount);
        assertEq(token.balanceOf(bob), amount);
    }

    function testFuzz_amountAboveAnyFiniteAllowanceReverts(uint256 approvedSeed, uint256 amountSeed) public {
        uint256 approved = bound(approvedSeed, 0, type(uint256).max - 1);
        uint256 amount = bound(amountSeed, approved + 1, type(uint256).max);
        token.approve(spender, approved);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, amount);
    }

    function testFuzz_infiniteAllowanceNeverOutrunsTheBalance(uint256 fundedSeed, uint256 amountSeed) public {
        uint256 funded = bound(fundedSeed, 0, SUPPLY);
        uint256 amount = bound(amountSeed, funded + 1, type(uint256).max);
        token.transfer(alice, funded);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funded, amount));
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
    }

    function testFuzz_strangerCannotPullAnything(uint256 strangerSeed, uint256 amountSeed) public {
        address stranger = _account(strangerSeed);
        uint256 amount = bound(amountSeed, 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        vm.prank(stranger);
        token.transferFrom(address(this), stranger, amount);
    }

    function testFuzz_approvingNeverMovesTokens(uint256 spenderSeed, uint256 amount) public {
        address approved = _account(spenderSeed);
        assertTrue(token.approve(approved, amount));

        assertEq(token.allowance(address(this), approved), amount);
        assertEq(token.allowance(approved, address(this)), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(approved), 0);
    }
}
