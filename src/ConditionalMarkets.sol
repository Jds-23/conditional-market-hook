// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Minimal ERC20 with owner-restricted mint/burn. Owner is always the ConditionalMarkets contract.
contract OutcomeToken is ERC20, Ownable {
    string internal _name;
    string internal _symbol;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
        _initializeOwner(msg.sender);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}

/// @notice Factory + escrow for binary outcome prediction markets.
/// Deploys YES/NO tokens per condition, handles split/merge/redeem lifecycle.
contract ConditionalMarkets {
    // ── Data Model ──────────────────────────────────────────────────────

    struct Condition {
        address collateralToken;
        address yesToken;
        address noToken;
    }

    mapping(bytes32 => Condition) public conditions;
    mapping(bytes32 => mapping(address => uint256)) public collateralBalances;
    mapping(bytes32 => address) public resolved;
    mapping(address => bytes32) public tokenCondition;

    // ── Errors ──────────────────────────────────────────────────────────

    error InvalidConditionId();
    error ConditionAlreadyExists(bytes32 conditionId);
    error InvalidWinner(address winner);
    error ConditionAlreadyResolved();
    error ConditionNotResolved(bytes32 conditionId);
    error TokenNotWinner(address token);
    error UnknownToken(address token);
    error ZeroAmount();
    error InsufficientBalance(address token, uint256 requested, uint256 available);

    // ── Events ──────────────────────────────────────────────────────────

    event ConditionCreated(
        bytes32 indexed conditionId, address collateralToken, address yesToken, address noToken
    );
    event Split(bytes32 indexed conditionId, address indexed sender, uint256 amount);
    event Merged(bytes32 indexed conditionId, address indexed sender, uint256 amount);
    event Resolved(bytes32 indexed conditionId, address indexed winner);
    event Redeemed(
        bytes32 indexed conditionId, address indexed sender, address indexed token, uint256 amount
    );

    // ── Modifiers ───────────────────────────────────────────────────────

    modifier notResolved(bytes32 conditionId) {
        if (resolved[conditionId] != address(0)) revert ConditionAlreadyResolved();
        _;
    }

    // ── External Functions ──────────────────────────────────────────────

    function createCondition(bytes32 conditionId, address collateralToken) external {
        if (conditionId == bytes32(0)) revert InvalidConditionId();
        if (conditions[conditionId].collateralToken != address(0)) {
            revert ConditionAlreadyExists(conditionId);
        }

        string memory hexId = _bytes32ToHexString(conditionId);

        OutcomeToken yesToken =
            new OutcomeToken(string.concat("YES-", hexId), "YES");
        OutcomeToken noToken =
            new OutcomeToken(string.concat("NO-", hexId), "NO");

        conditions[conditionId] = Condition({
            collateralToken: collateralToken,
            yesToken: address(yesToken),
            noToken: address(noToken)
        });

        tokenCondition[address(yesToken)] = conditionId;
        tokenCondition[address(noToken)] = conditionId;

        emit ConditionCreated(conditionId, collateralToken, address(yesToken), address(noToken));
    }

    function split(bytes32 conditionId, uint256 amount) external notResolved(conditionId) {
        Condition storage c = conditions[conditionId];

        SafeTransferLib.safeTransferFrom(c.collateralToken, msg.sender, address(this), amount);
        collateralBalances[conditionId][c.collateralToken] += amount;

        OutcomeToken(c.yesToken).mint(msg.sender, amount);
        OutcomeToken(c.noToken).mint(msg.sender, amount);

        emit Split(conditionId, msg.sender, amount);
    }

    function merge(bytes32 conditionId, uint256 amount) external notResolved(conditionId) {
        Condition storage c = conditions[conditionId];

        OutcomeToken(c.yesToken).burn(msg.sender, amount);
        OutcomeToken(c.noToken).burn(msg.sender, amount);

        collateralBalances[conditionId][c.collateralToken] -= amount;
        SafeTransferLib.safeTransfer(c.collateralToken, msg.sender, amount);

        emit Merged(conditionId, msg.sender, amount);
    }

    function resolve(bytes32 conditionId, address winner) external {
        if (resolved[conditionId] != address(0)) revert ConditionAlreadyResolved();

        Condition storage c = conditions[conditionId];
        if (winner != c.yesToken && winner != c.noToken) revert InvalidWinner(winner);

        resolved[conditionId] = winner;

        emit Resolved(conditionId, winner);
    }

    function redeem(address token, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        bytes32 conditionId = tokenCondition[token];
        if (conditionId == bytes32(0)) revert UnknownToken(token);

        address winner = resolved[conditionId];
        if (winner == address(0)) revert ConditionNotResolved(conditionId);
        if (token != winner) revert TokenNotWinner(token);

        uint256 balance = ERC20(token).balanceOf(msg.sender);
        if (balance < amount) revert InsufficientBalance(token, amount, balance);

        Condition storage c = conditions[conditionId];

        OutcomeToken(token).burn(msg.sender, amount);
        collateralBalances[conditionId][c.collateralToken] -= amount;
        SafeTransferLib.safeTransfer(c.collateralToken, msg.sender, amount);

        emit Redeemed(conditionId, msg.sender, token, amount);
    }

    // ── Internal Helpers ────────────────────────────────────────────────

    function _bytes32ToHexString(bytes32 value) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(66); // "0x" + 64 hex chars
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(str);
    }
}
