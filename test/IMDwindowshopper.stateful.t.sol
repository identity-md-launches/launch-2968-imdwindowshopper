// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDwindowshopper} from "../src/IMDwindowshopper.sol";

uint256 constant WWW_SUPPLY = 1_000_000_000 * 10 ** 18;

/// @dev A holder that is a contract and fails on any call to it.
contract RejectingContractActor {
    receive() external payable {
        revert("actor was called");
    }

    fallback() external payable {
        revert("actor was called");
    }
}

/// @notice Drives the token through both accepted and rejected calls, at the edges of each amount.
/// @dev Every function performs a real call and never skips, so a run cannot pass by doing nothing. Each one
/// checks that call's own postconditions; running totals are kept for the invariants to compare afterwards.
/// A rejected call must fail with the exact error expected, not merely fail.
contract WwwStatefulHandler is Test {
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");

    IMDwindowshopper public immutable token;
    address public immutable deployer;

    /// @dev Addresses the handler can act as.
    address[] internal actors;
    /// @dev The actors plus the token's own address, which can receive but has no way to send.
    address[] internal accounts;

    mapping(address => uint256) public initialBalance;
    mapping(address => uint256) public received;
    mapping(address => uint256) public sent;

    mapping(address => mapping(address => uint256)) public modelAllowance;
    mapping(address => mapping(address => uint256)) public granted;
    mapping(address => mapping(address => uint256)) public spent;
    mapping(address => mapping(address => bool)) public everUnlimited;

    uint256 public acceptedMoves;
    uint256 public acceptedApprovals;
    uint256 public rejectedCalls;

    constructor(IMDwindowshopper token_, address deployer_, address[] memory actors_) {
        token = token_;
        deployer = deployer_;
        for (uint256 i; i < actors_.length; ++i) {
            actors.push(actors_[i]);
            accounts.push(actors_[i]);
            initialBalance[actors_[i]] = token_.balanceOf(actors_[i]);
        }
        accounts.push(address(token_));
        initialBalance[address(token_)] = token_.balanceOf(address(token_));
    }

    function allActors() external view returns (address[] memory) {
        return actors;
    }

    function allAccounts() external view returns (address[] memory) {
        return accounts;
    }

    // ---------------------------------------------------------------- calls that must succeed

    function transferWithinBalance(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _anyAccount(toSeed);
        uint256 amount = _edgeAmount(amountSeed, token.balanceOf(from));
        _executeMove(from, from, to, amount, abi.encodeCall(IERC20.transfer, (to, amount)));
    }

    function transferFromWithinAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _anyAccount(toSeed);
        uint256 approved = token.allowance(owner, spender);
        uint256 amount = _edgeAmount(amountSeed, _min(approved, token.balanceOf(owner)));

        _executeMove(spender, owner, to, amount, abi.encodeCall(IERC20.transferFrom, (owner, to, amount)));

        if (approved != type(uint256).max) modelAllowance[owner][spender] = approved - amount;
        spent[owner][spender] += amount;
        assertEq(token.allowance(owner, spender), modelAllowance[owner][spender], "spending moved allowance wrongly");
    }

    function approveAny(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _edgeApproval(amountSeed);
        bytes memory data = abi.encodeCall(IERC20.approve, (spender, amount));

        vm.recordLogs();
        vm.prank(owner);
        (bool ok, bytes memory returned) = address(token).call(data);

        assertTrue(ok, "a valid approval reverted");
        assertEq(returned, abi.encode(true), "approve did not return the word true");
        _assertSingleLog(APPROVAL_TOPIC, owner, spender, amount);
        assertEq(token.allowance(owner, spender), amount, "approve did not set the allowance");
        _recordGrant(owner, spender, amount);
        ++acceptedApprovals;
    }

    // ---------------------------------------------------------------- calls that must be rejected

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _anyAccount(toSeed);
        uint256 held = token.balanceOf(from);
        uint256 amount = bound(amountSeed, held + 1, type(uint256).max);
        _assertRejected(
            from,
            abi.encodeCall(IERC20.transfer, (to, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount)
        );
    }

    function transferToZero(uint256 fromSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        uint256 amount = _edgeAmount(amountSeed, token.balanceOf(from));
        _assertRejected(
            from,
            abi.encodeCall(IERC20.transfer, (address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    function transferAsZeroCaller(uint256 toSeed, uint256 amount) external {
        _assertRejected(
            address(0),
            abi.encodeCall(IERC20.transfer, (_anyAccount(toSeed), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0))
        );
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        _assertRejected(
            _actor(ownerSeed),
            abi.encodeCall(IERC20.approve, (address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
        );
    }

    function approveAsZeroCaller(uint256 spenderSeed, uint256 amount) external {
        _assertRejected(
            address(0),
            abi.encodeCall(IERC20.approve, (_actor(spenderSeed), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0))
        );
    }

    function transferFromAboveAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _anyAccount(toSeed);
        uint256 approved = token.allowance(owner, spender);
        if (approved == type(uint256).max) {
            // Nothing lies above an unlimited allowance, so the balance is the limit that gets tested.
            _rejectAboveBalance(owner, spender, to, amountSeed);
            return;
        }
        uint256 amount = bound(amountSeed, approved + 1, type(uint256).max);
        _assertRejected(
            spender,
            abi.encodeCall(IERC20.transferFrom, (owner, to, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
    }

    function transferFromAboveBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed)
        external
    {
        _rejectAboveBalance(_actor(ownerSeed), _actor(spenderSeed), _anyAccount(toSeed), amountSeed);
    }

    function transferFromToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _edgeAmount(amountSeed, _min(token.allowance(owner, spender), token.balanceOf(owner)));
        _assertRejected(
            spender,
            abi.encodeCall(IERC20.transferFrom, (owner, address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    /// @dev The stranger never appears in `actors`, so nothing has ever approved it.
    function strangerPull(uint256 ownerSeed, uint256 strangerSeed, uint256 toSeed, uint256 amountSeed) external {
        address stranger = address(uint160(uint256(keccak256(abi.encode("www.stranger", strangerSeed)))));
        uint256 amount = bound(amountSeed, 1, type(uint256).max);
        _assertRejected(
            stranger,
            abi.encodeCall(IERC20.transferFrom, (_actor(ownerSeed), _anyAccount(toSeed), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount)
        );
    }

    function transferFromZeroOwner(uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address spender = _actor(spenderSeed);
        uint256 amount = amountSeed % 4 == 0 ? 0 : bound(amountSeed, 1, type(uint256).max);
        bytes memory expected = amount == 0
            ? abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0))
            : abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount);
        _assertRejected(
            spender, abi.encodeCall(IERC20.transferFrom, (address(0), _anyAccount(toSeed), amount)), expected
        );
    }

    function transferFromAsZeroCaller(uint256 ownerSeed, uint256 toSeed, uint256 amountSeed) external {
        uint256 amount = amountSeed % 4 == 0 ? 0 : bound(amountSeed, 1, type(uint256).max);
        bytes memory expected = amount == 0
            ? abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
            : abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(0), 0, amount);
        _assertRejected(
            address(0), abi.encodeCall(IERC20.transferFrom, (_actor(ownerSeed), _anyAccount(toSeed), amount)), expected
        );
    }

    function forbiddenEntrypoint(uint256 callerSeed, uint256 whichSeed) external {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "seize(address)",
            "transferOwnership(address)",
            "renounceOwnership()",
            "upgradeTo(address)",
            "setMinter(address)",
            "initialize(address)"
        ];
        address caller = callerSeed % 4 == 0 ? deployer : _actor(callerSeed);
        bytes memory data = abi.encodeWithSignature(signatures[whichSeed % signatures.length], caller, uint256(1));
        _assertRejected(caller, data, bytes(""));
    }

    function sendNativeValue(uint256 senderSeed, uint256 valueSeed) external {
        address sender = _actor(senderSeed);
        uint256 value = bound(valueSeed, 1, 1 ether);
        vm.deal(sender, value);
        vm.prank(sender);
        (bool ok,) = address(token).call{value: value}("");
        assertFalse(ok, "the token accepted native value");
        ++rejectedCalls;
    }

    // ---------------------------------------------------------------- internals

    function _executeMove(address caller, address from, address to, uint256 amount, bytes memory data) internal {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.recordLogs();
        vm.prank(caller);
        (bool ok, bytes memory returned) = address(token).call(data);

        assertTrue(ok, "a move within every limit reverted");
        assertEq(returned, abi.encode(true), "the move did not return the word true");
        _assertSingleLog(TRANSFER_TOPIC, from, to, amount);
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "a self transfer changed the balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "the sender lost the wrong amount");
            assertEq(token.balanceOf(to), toBefore + amount, "the receiver gained the wrong amount");
        }
        sent[from] += amount;
        received[to] += amount;
        ++acceptedMoves;
    }

    function _rejectAboveBalance(address owner, address spender, address to, uint256 amountSeed) internal {
        uint256 held = token.balanceOf(owner);
        uint256 approved = token.allowance(owner, spender);
        if (approved <= held) {
            // Grant more than the owner holds, so the balance rather than the allowance is what stops it.
            approved = held + 1 + (amountSeed % 1_000);
            vm.prank(owner);
            token.approve(spender, approved);
            _recordGrant(owner, spender, approved);
        }
        uint256 amount = bound(amountSeed, held + 1, approved);
        _assertRejected(
            spender,
            abi.encodeCall(IERC20.transferFrom, (owner, to, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount)
        );
    }

    function _assertRejected(address caller, bytes memory data, bytes memory expectedError) internal {
        vm.prank(caller);
        (bool ok, bytes memory returned) = address(token).call(data);
        assertFalse(ok, "a call that must be rejected succeeded");
        assertEq(returned, expectedError, "the call failed with the wrong error");
        ++rejectedCalls;
    }

    function _assertSingleLog(bytes32 topic, address first, address second, uint256 value) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "the call did not emit exactly one event");
        assertEq(logs[0].emitter, address(token), "the event came from elsewhere");
        assertEq(logs[0].topics.length, 3, "the event has the wrong shape");
        assertEq(logs[0].topics[0], topic, "the wrong event was emitted");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(first))), "the event names the wrong first party");
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(second))), "the event names the wrong second party");
        assertEq(abi.decode(logs[0].data, (uint256)), value, "the event states the wrong value");
    }

    function _recordGrant(address owner, address spender, uint256 amount) internal {
        modelAllowance[owner][spender] = amount;
        if (amount == type(uint256).max) {
            everUnlimited[owner][spender] = true;
            return;
        }
        uint256 total = granted[owner][spender];
        granted[owner][spender] = amount > type(uint256).max - total ? type(uint256).max : total + amount;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _anyAccount(uint256 seed) internal view returns (address) {
        return accounts[seed % accounts.length];
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Zero, one wei, the whole limit, or anything between them.
    function _edgeAmount(uint256 seed, uint256 limit) internal pure returns (uint256) {
        uint256 mode = seed % 4;
        if (mode == 0) return 0;
        if (mode == 1) return limit == 0 ? 0 : 1;
        if (mode == 2) return limit;
        return bound(seed >> 2, 0, limit);
    }

    /// @dev Zero, unlimited, a realistic amount, or any value at all.
    function _edgeApproval(uint256 seed) internal pure returns (uint256) {
        uint256 mode = seed % 4;
        if (mode == 0) return 0;
        if (mode == 1) return type(uint256).max;
        if (mode == 2) return bound(seed >> 2, 0, WWW_SUPPLY);
        return seed;
    }
}

/// @dev The closed set of holders both test contracts below start from: a large one, a mid one, one with a
/// single wei, an empty one and a contract. Whatever the deployer still holds goes to the large one.
abstract contract WwwStatefulFixture is Test {
    function _deployHandler(IMDwindowshopper token_) internal returns (WwwStatefulHandler) {
        address[] memory holders = new address[](5);
        holders[0] = makeAddr("whale");
        holders[1] = makeAddr("mid");
        holders[2] = makeAddr("dust");
        holders[3] = makeAddr("empty");
        holders[4] = address(new RejectingContractActor());

        token_.transfer(holders[1], WWW_SUPPLY / 4);
        token_.transfer(holders[2], 1);
        token_.transfer(holders[4], WWW_SUPPLY / 8);
        token_.transfer(holders[0], token_.balanceOf(address(this)));
        return new WwwStatefulHandler(token_, address(this), holders);
    }
}

contract IMDwindowshopperStatefulInvariantTest is WwwStatefulFixture {
    IMDwindowshopper internal token;
    WwwStatefulHandler internal handler;
    bytes32 internal runtimeHash;

    function setUp() public {
        token = new IMDwindowshopper();
        runtimeHash = address(token).codehash;
        handler = _deployHandler(token);

        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = WwwStatefulHandler.transferWithinBalance.selector;
        selectors[1] = WwwStatefulHandler.transferFromWithinAllowance.selector;
        selectors[2] = WwwStatefulHandler.approveAny.selector;
        selectors[3] = WwwStatefulHandler.transferAboveBalance.selector;
        selectors[4] = WwwStatefulHandler.transferToZero.selector;
        selectors[5] = WwwStatefulHandler.transferAsZeroCaller.selector;
        selectors[6] = WwwStatefulHandler.approveZeroSpender.selector;
        selectors[7] = WwwStatefulHandler.approveAsZeroCaller.selector;
        selectors[8] = WwwStatefulHandler.transferFromAboveAllowance.selector;
        selectors[9] = WwwStatefulHandler.transferFromAboveBalance.selector;
        selectors[10] = WwwStatefulHandler.transferFromToZero.selector;
        selectors[11] = WwwStatefulHandler.strangerPull.selector;
        selectors[12] = WwwStatefulHandler.transferFromZeroOwner.selector;
        selectors[13] = WwwStatefulHandler.forbiddenEntrypoint.selector;
        selectors[14] = WwwStatefulHandler.sendNativeValue.selector;
        selectors[15] = WwwStatefulHandler.transferFromAsZeroCaller.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // A fixed supply never changes, and the closed set of accounts holds all of it.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyIsFixedAndFullyHeldByKnownAccounts() public view {
        address[] memory accounts = handler.allAccounts();
        uint256 sum;
        for (uint256 i; i < accounts.length; ++i) {
            sum += token.balanceOf(accounts[i]);
        }
        assertEq(sum, WWW_SUPPLY, "the known accounts do not hold the whole supply");
        assertEq(token.totalSupply(), WWW_SUPPLY, "the supply changed");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(handler)), 0, "the handler holds tokens");
    }

    // Each balance is what the account started with, plus what reached it, less what left it.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesMatchRecordedFlows() public view {
        address[] memory accounts = handler.allAccounts();
        uint256 totalReceived;
        uint256 totalSent;
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            assertEq(
                token.balanceOf(account) + handler.sent(account),
                handler.initialBalance(account) + handler.received(account),
                "a balance disagrees with the recorded flows"
            );
            totalReceived += handler.received(account);
            totalSent += handler.sent(account);
        }
        assertEq(totalReceived, totalSent, "tokens were created or destroyed in flight");
    }

    // Allowances follow the approvals, and a spender never moves more than it was ever granted.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_allowancesMatchAndSpendingIsBounded() public view {
        address[] memory actors = handler.allActors();
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                (address owner, address spender) = (actors[i], actors[j]);
                assertEq(
                    token.allowance(owner, spender),
                    handler.modelAllowance(owner, spender),
                    "an allowance disagrees with the approvals made"
                );
                if (!handler.everUnlimited(owner, spender)) {
                    assertLe(handler.spent(owner, spender), handler.granted(owner, spender), "overspent");
                }
            }
            assertEq(token.allowance(actors[i], address(0)), 0, "an allowance exists for the zero address");
            assertEq(token.allowance(address(0), actors[i]), 0, "an allowance exists from the zero address");
        }
    }

    // The token's own address can receive and has no way to send: what reaches it stays there.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_nothingLeavesTheTokenContract() public view {
        assertEq(token.balanceOf(address(token)), handler.received(address(token)), "tokens left the token contract");
        address[] memory actors = handler.allActors();
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.allowance(address(token), actors[i]), 0, "the token contract has granted an allowance");
        }
    }

    // Nothing a call sequence can do alters what the token is.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_identityCodeAndNativeBalanceNeverChange() public view {
        assertEq(token.name(), "IMDwindowshopper");
        assertEq(token.symbol(), "WWW");
        assertEq(uint256(token.decimals()), 18);
        assertEq(token.INITIAL_SUPPLY(), WWW_SUPPLY);
        assertEq(address(token).codehash, runtimeHash, "the runtime code changed");
        assertEq(address(token).balance, 0, "the token holds native currency");
    }
}

// ---------------------------------------------------------------- broken tokens, for the handler's own sake

/// @dev Skims one percent of every ordinary transfer, burning it. Would short the launch's flows.
contract FeeOnTransferMutant is ERC20 {
    constructor() ERC20("Mutant", "MUT") {
        _mint(msg.sender, WWW_SUPPLY);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value / 100;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, address(0), fee);
    }
}

/// @dev Never consumes an allowance: one approval can be spent again and again.
contract UnspentAllowanceMutant is ERC20 {
    constructor() ERC20("Mutant", "MUT") {
        _mint(msg.sender, WWW_SUPPLY);
    }

    function _spendAllowance(address, address, uint256) internal override {}
}

/// @dev Anyone can mint.
contract OpenMintMutant is ERC20 {
    constructor() ERC20("Mutant", "MUT") {
        _mint(msg.sender, WWW_SUPPLY);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Shows the handler can tell a broken token from a sound one, so a passing campaign means something.
/// Each mutant gets the exact call that the real token passes, and the handler has to refuse it.
contract WwwStatefulHandlerControlTest is WwwStatefulFixture {
    uint256 internal constant WHALE = 0;
    uint256 internal constant MID = 1;
    uint256 internal constant DUST = 2;
    uint256 internal constant EMPTY = 3;
    uint256 internal constant CONTRACT_HOLDER = 4;
    uint256 internal constant TOKEN_ITSELF = 5;

    // Amount seeds for `_edgeAmount`.
    uint256 internal constant ZERO_AMOUNT = 0;
    uint256 internal constant ONE_WEI = 1;
    uint256 internal constant WHOLE_LIMIT = 2;
    // Approval seeds for `_edgeApproval`: 22 % 4 selects the bounded mode, and 22 >> 2 is 5.
    uint256 internal constant APPROVE_FIVE = 22;
    uint256 internal constant APPROVE_UNLIMITED = 1;

    function _handlerForRealToken() internal returns (WwwStatefulHandler) {
        return _deployHandler(new IMDwindowshopper());
    }

    function _handlerFor(address mutant) internal returns (WwwStatefulHandler) {
        return _deployHandler(IMDwindowshopper(mutant));
    }

    function _assertRefused(WwwStatefulHandler mutantHandler, bytes memory data) internal {
        (bool ok,) = address(mutantHandler).call(data);
        assertFalse(ok, "the handler passed a broken token");
    }

    function test_realTokenPassesEveryHandlerPath() public {
        WwwStatefulHandler h = _handlerForRealToken();
        IMDwindowshopper real = h.token();
        address whale = h.allActors()[WHALE];
        address mid = h.allActors()[MID];

        h.transferWithinBalance(WHALE, MID, ONE_WEI);
        h.transferWithinBalance(WHALE, TOKEN_ITSELF, ONE_WEI);
        h.transferWithinBalance(WHALE, WHALE, WHOLE_LIMIT);
        h.transferWithinBalance(EMPTY, DUST, WHOLE_LIMIT);
        h.approveAny(WHALE, MID, APPROVE_FIVE);
        h.transferFromWithinAllowance(WHALE, MID, DUST, WHOLE_LIMIT);
        h.approveAny(WHALE, MID, APPROVE_UNLIMITED);
        h.transferFromWithinAllowance(WHALE, MID, DUST, ONE_WEI);
        assertEq(h.acceptedMoves(), 6);
        assertEq(h.acceptedApprovals(), 2);
        assertEq(h.spent(whale, mid), 6);
        assertEq(real.balanceOf(address(real)), 1);
        assertEq(h.received(address(real)), 1);
        assertEq(real.allowance(whale, mid), type(uint256).max);

        h.transferAboveBalance(EMPTY, MID, 0);
        h.transferAboveBalance(WHALE, CONTRACT_HOLDER, type(uint256).max);
        h.transferToZero(DUST, WHOLE_LIMIT);
        h.transferAsZeroCaller(MID, 0);
        h.approveZeroSpender(WHALE, 1);
        h.approveAsZeroCaller(MID, 1);
        // The whale's unlimited grant to mid leaves the balance as the limit; mid has granted the whale nothing.
        h.transferFromAboveAllowance(WHALE, MID, DUST, 0);
        h.transferFromAboveAllowance(MID, WHALE, DUST, 0);
        // Allowance at or below the balance, so the handler has to widen it first.
        h.transferFromAboveBalance(DUST, EMPTY, MID, 0);
        h.transferFromToZero(WHALE, MID, ONE_WEI);
        h.strangerPull(WHALE, 7, MID, 0);
        h.transferFromZeroOwner(WHALE, MID, ZERO_AMOUNT);
        h.transferFromZeroOwner(WHALE, MID, ONE_WEI);
        h.transferFromAsZeroCaller(WHALE, MID, ZERO_AMOUNT);
        h.transferFromAsZeroCaller(WHALE, MID, ONE_WEI);
        h.forbiddenEntrypoint(0, 0);
        h.forbiddenEntrypoint(1, 13);
        h.sendNativeValue(WHALE, 0);
        assertEq(h.rejectedCalls(), 18);

        assertEq(real.totalSupply(), WWW_SUPPLY);
        assertEq(address(real).balance, 0);
    }

    function test_feeOnTransferIsCaught() public {
        WwwStatefulHandler h = _handlerFor(address(new FeeOnTransferMutant()));
        _assertRefused(h, abi.encodeCall(h.transferWithinBalance, (WHALE, MID, WHOLE_LIMIT)));
    }

    function test_unspentAllowanceIsCaught() public {
        WwwStatefulHandler h = _handlerFor(address(new UnspentAllowanceMutant()));
        h.approveAny(WHALE, MID, APPROVE_FIVE);
        _assertRefused(h, abi.encodeCall(h.transferFromWithinAllowance, (WHALE, MID, DUST, WHOLE_LIMIT)));
    }

    function test_openMintIsCaught() public {
        WwwStatefulHandler h = _handlerFor(address(new OpenMintMutant()));
        // Index 0 is mint(address,uint256), called as an actor.
        _assertRefused(h, abi.encodeCall(h.forbiddenEntrypoint, (WHALE + 1, 0)));
    }
}
