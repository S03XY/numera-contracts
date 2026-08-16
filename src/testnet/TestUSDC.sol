// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ZeroAddress} from "../libraries/Errors.sol";

/// @title TestUSDC
/// @notice A testnet stand-in for Circle's USDC that behaves like the real thing.
///
/// @dev **Testnet only — never deployed to mainnet**, where the collateral is real USDC.
///
///      ## Why this mimics `FiatTokenV2_2` rather than being a plain ERC-20
///
///      Numera settles in USDC. Building against a simplified token means every difference between
///      it and the real one is discovered in production, and the differences that matter here are
///      not cosmetic — they are the ones that decide whether a signature verifies and whether a
///      trade can settle at all. Concretely:
///
///      - **EIP-712 domain version `"2"`, not `"1"`.** OpenZeppelin's `ERC20Permit` hardcodes `"1"`;
///        USDC uses `"2"`. A client that assumes `"1"` produces permits that recover to a *different
///        address*, so `permit` reverts with nothing that explains why. Using OZ's helper here would
///        have hidden that until mainnet.
///      - **No ERC-5267 `eip712Domain()`.** USDC predates it and does not implement it, so a client
///        cannot discover the domain that way. It exposes {version} and {DOMAIN_SEPARATOR} instead,
///        and this does the same — otherwise our discovery path would be tested against a capability
///        real USDC does not have.
///      - **Blacklisting.** Circle can freeze an address, and a frozen market account is a real
///        operational state the app has to survive rather than a hypothetical.
///      - **Pausing**, **minter allowances**, and **EIP-3009** authorizations, all of which real
///        integrations rely on.
///
///      ## What is deliberately NOT mimicked
///
///      Upgradeability. USDC sits behind a proxy Circle can upgrade; reproducing that would add a
///      moving part with no test value, and it changes nothing about the token interface.
///
///      ## The one addition
///
///      {faucet}, because a testnet needs a way to get funds and Circle's faucet only dispenses on
///      chains they support. It is the single function here with no counterpart in real USDC.
contract TestUSDC is ERC20, Pausable {
    /// @notice EIP-712 domain version. `"2"`, matching Circle — see the note above.
    string public constant version = "2";

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant _TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 private constant _RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 private constant _CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    /// @notice Tokens dispensed per faucet call (1,000 USDC at 6 decimals).
    uint256 public constant FAUCET_AMOUNT = 1_000e6;

    /// @notice Minimum wait between faucet calls for one address.
    /// @dev Six hours: long enough to stop a single tester flooding the books, short enough that a
    ///      tester who genuinely loses a session's funds is not blocked for a day.
    uint256 public constant FAUCET_COOLDOWN = 6 hours;

    /// @notice Circle's role split, reproduced. One address holds all of them here.
    address public owner;
    address public masterMinter;
    address public pauser;
    address public blacklister;

    /// @notice Per-minter allowance, exactly as Circle's `configureMinter` works.
    mapping(address minter => bool enabled) public isMinter;
    mapping(address minter => uint256 allowance) public minterAllowance;

    mapping(address account => bool frozen) internal _blacklisted;

    /// @notice EIP-2612 nonces. Sequential, per owner.
    mapping(address owner => uint256 nonce) public nonces;

    /// @notice EIP-3009 authorization state, keyed by an arbitrary 32-byte nonce.
    /// @dev Not sequential, unlike {nonces}: EIP-3009 nonces are caller-chosen so authorizations can
    ///      be issued out of order and cancelled individually.
    mapping(address authorizer => mapping(bytes32 nonce => bool used)) public authorizationState;

    mapping(address account => uint256 timestamp) public nextFaucetAt;

    event FaucetClaimed(address indexed account, uint256 amount, uint256 nextEligibleAt);
    event Blacklisted(address indexed account);
    event UnBlacklisted(address indexed account);
    event MinterConfigured(address indexed minter, uint256 minterAllowedAmount);
    event MinterRemoved(address indexed minter);
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    error FaucetCooldown(uint256 availableAt);
    error NotOwner();
    error NotMasterMinter();
    error NotMinter();
    error NotPauser();
    error NotBlacklister();
    error AccountBlacklisted(address account);
    error ExceedsMinterAllowance(uint256 requested, uint256 allowed);
    error PermitExpired(uint256 deadline);
    error InvalidSignature();
    error AuthorizationNotYetValid(uint256 validAfter);
    error AuthorizationExpired(uint256 validBefore);
    error AuthorizationAlreadyUsed(bytes32 nonce);
    error CallerMustBePayee(address caller, address payee);

    constructor(address admin_) ERC20("USD Coin", "USDC") {
        if (admin_ == address(0)) revert ZeroAddress();
        owner = admin_;
        masterMinter = admin_;
        pauser = admin_;
        blacklister = admin_;
        // The deployer is a minter with no cap, so seeding a market needs no extra step.
        isMinter[admin_] = true;
        minterAllowance[admin_] = type(uint256).max;
        emit MinterConfigured(admin_, type(uint256).max);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier notBlacklisted(address account) {
        if (_blacklisted[account]) revert AccountBlacklisted(account);
        _;
    }

    /// @inheritdoc ERC20
    /// @dev Matches real USDC so amounts, price formatting and `COLLATERAL_DECIMALS` all agree.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // -------------------------------------------------------------------------
    // EIP-712
    // -------------------------------------------------------------------------

    /// @notice The EIP-712 domain separator, the way Circle exposes it.
    /// @dev Recomputed per call rather than cached, so a chain fork cannot leave a stale `chainId`
    ///      baked in — the defect Circle had to ship `FiatTokenV2_2` to fix.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                keccak256(bytes(name())),
                keccak256(bytes(version)),
                block.chainid,
                address(this)
            )
        );
    }

    function _verify(bytes32 structHash, address signer, uint8 v, bytes32 r, bytes32 s) private view {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, v, r, s);
        if (err != ECDSA.RecoverError.NoError || recovered != signer) revert InvalidSignature();
    }

    // -------------------------------------------------------------------------
    // EIP-2612
    // -------------------------------------------------------------------------

    /// @notice Approve by signature, so an account holding no gas can still grant an allowance.
    /// @dev The mechanism Numera's market accounts depend on: they never hold native gas, so this
    ///      is the only way they can authorise the engine to pull collateral.
    function permit(
        address tokenOwner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused notBlacklisted(tokenOwner) notBlacklisted(spender) {
        if (block.timestamp > deadline) revert PermitExpired(deadline);
        _verify(
            keccak256(
                abi.encode(_PERMIT_TYPEHASH, tokenOwner, spender, value, nonces[tokenOwner]++, deadline)
            ),
            tokenOwner,
            v,
            r,
            s
        );
        _approve(tokenOwner, spender, value);
    }

    // -------------------------------------------------------------------------
    // EIP-3009
    // -------------------------------------------------------------------------

    /// @notice Transfer by signature. The payer signs; anyone may submit.
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _useAuthorization(
            _TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, v, r, s
        );
        _transfer(from, to, value);
    }

    /// @notice Like {transferWithAuthorization}, but only the payee may submit it.
    /// @dev Front-running protection: a bare `transferWithAuthorization` can be submitted by anyone,
    ///      which lets a third party land it at a moment of their choosing.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (msg.sender != to) revert CallerMustBePayee(msg.sender, to);
        _useAuthorization(
            _RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, v, r, s
        );
        _transfer(from, to, value);
    }

    /// @notice Burn an unused authorization nonce.
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        if (authorizationState[authorizer][nonce]) revert AuthorizationAlreadyUsed(nonce);
        _verify(keccak256(abi.encode(_CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)), authorizer, v, r, s);
        authorizationState[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    /// @dev Split out because the two authorization entry points differ only in their typehash and
    ///      in who may submit them; duplicating the window and nonce checks is how one of them drifts.
    function _useAuthorization(
        bytes32 typehash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) private {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid(validAfter);
        if (block.timestamp >= validBefore) revert AuthorizationExpired(validBefore);
        if (authorizationState[from][nonce]) revert AuthorizationAlreadyUsed(nonce);

        _verify(
            keccak256(abi.encode(typehash, from, to, value, validAfter, validBefore, nonce)), from, v, r, s
        );
        authorizationState[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
    }

    // -------------------------------------------------------------------------
    // Blacklist / pause
    // -------------------------------------------------------------------------

    function isBlacklisted(address account) public view returns (bool) {
        return _blacklisted[account];
    }

    function blacklist(address account) external {
        if (msg.sender != blacklister) revert NotBlacklister();
        _blacklisted[account] = true;
        emit Blacklisted(account);
    }

    function unBlacklist(address account) external {
        if (msg.sender != blacklister) revert NotBlacklister();
        _blacklisted[account] = false;
        emit UnBlacklisted(account);
    }

    function pause() external {
        if (msg.sender != pauser) revert NotPauser();
        _pause();
    }

    function unpause() external {
        if (msg.sender != pauser) revert NotPauser();
        _unpause();
    }

    /// @dev Every balance change funnels through here in OZ v5 — transfer, mint and burn alike — so
    ///      one override covers the whole surface. Circle applies the same two rules.
    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        if (from != address(0) && _blacklisted[from]) revert AccountBlacklisted(from);
        if (to != address(0) && _blacklisted[to]) revert AccountBlacklisted(to);
        super._update(from, to, value);
    }

    /// @inheritdoc ERC20
    /// @dev Circle blocks a blacklisted party from granting or receiving an allowance, not just from
    ///      moving tokens. Without this a frozen account could still hand out spending rights.
    function _approve(address tokenOwner, address spender, uint256 value, bool emitEvent)
        internal
        override
        notBlacklisted(tokenOwner)
        notBlacklisted(spender)
    {
        super._approve(tokenOwner, spender, value, emitEvent);
    }

    // -------------------------------------------------------------------------
    // Minting
    // -------------------------------------------------------------------------

    function configureMinter(address minter, uint256 minterAllowedAmount) external {
        if (msg.sender != masterMinter) revert NotMasterMinter();
        isMinter[minter] = true;
        minterAllowance[minter] = minterAllowedAmount;
        emit MinterConfigured(minter, minterAllowedAmount);
    }

    function removeMinter(address minter) external {
        if (msg.sender != masterMinter) revert NotMasterMinter();
        isMinter[minter] = false;
        minterAllowance[minter] = 0;
        emit MinterRemoved(minter);
    }

    /// @notice Mint within the caller's minter allowance, exactly as Circle's does.
    function mint(address to, uint256 amount) external whenNotPaused notBlacklisted(to) {
        if (!isMinter[msg.sender]) revert NotMinter();
        uint256 allowed = minterAllowance[msg.sender];
        if (amount > allowed) revert ExceedsMinterAllowance(amount, allowed);
        // An uncapped minter stays uncapped rather than counting down from `type(uint256).max`.
        if (allowed != type(uint256).max) minterAllowance[msg.sender] = allowed - amount;
        _mint(to, amount);
    }

    function burn(uint256 amount) external whenNotPaused {
        if (!isMinter[msg.sender]) revert NotMinter();
        _burn(msg.sender, amount);
    }

    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        owner = next;
    }

    function updateMasterMinter(address next) external onlyOwner {
        masterMinter = next;
    }

    function updatePauser(address next) external onlyOwner {
        pauser = next;
    }

    function updateBlacklister(address next) external onlyOwner {
        blacklister = next;
    }

    // -------------------------------------------------------------------------
    // Faucet — the one thing real USDC does not have
    // -------------------------------------------------------------------------

    /// @notice Mint {FAUCET_AMOUNT} to the caller, at most once per {FAUCET_COOLDOWN}.
    /// @dev Keyed on `msg.sender`, so a tester cannot mint without limit by rotating accounts within
    ///      one market. Deliberately outside the minter roles: it is not part of the USDC surface,
    ///      and gating it on one would misrepresent how the real token works.
    function faucet() external whenNotPaused notBlacklisted(msg.sender) {
        uint256 availableAt = nextFaucetAt[msg.sender];
        if (block.timestamp < availableAt) revert FaucetCooldown(availableAt);

        uint256 next = block.timestamp + FAUCET_COOLDOWN;
        nextFaucetAt[msg.sender] = next;

        _mint(msg.sender, FAUCET_AMOUNT);
        emit FaucetClaimed(msg.sender, FAUCET_AMOUNT, next);
    }

    /// @notice Seconds until `account` may call {faucet}; zero when it may claim now.
    function faucetCooldownRemaining(address account) external view returns (uint256) {
        uint256 availableAt = nextFaucetAt[account];
        return block.timestamp >= availableAt ? 0 : availableAt - block.timestamp;
    }
}
