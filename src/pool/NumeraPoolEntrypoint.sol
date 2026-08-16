// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IPrivacyPool} from "./interfaces/IPrivacyPool.sol";
import {IPoolEntrypoint} from "./interfaces/IPoolEntrypoint.sol";
import {ProofLib} from "./lib/ProofLib.sol";
import {ZeroAddress, AmountZero} from "../libraries/Errors.sol";

/**
 * @title NumeraPoolEntrypoint
 * @notice The only door into and out of Numera's shielded pool.
 *
 * ## What this replaces, and why it is smaller
 *
 * Upstream (0xbow's privacy-pools-core) the entrypoint is a UUPS proxy carrying a multi-asset
 * registry, vetting fees, relay fees, and role administration. Numera has one collateral token, no
 * fees, and one relayer, so nearly all of that is configuration for choices we have already made.
 * What remains is the part the pool genuinely cannot do without:
 *
 *  - somewhere to hold the **association-set root**, which every withdrawal proof is checked
 *    against ({IPoolEntrypoint.latestRoot});
 *  - a **deposit** path, because the pool only accepts deposits from its entrypoint;
 *  - a **relay** path, because a withdrawal pays out to `msg.sender`, and if that were the trader's
 *    own wallet the withdrawal would publish exactly the link the pool exists to break.
 *
 * ## The privacy claim, stated precisely
 *
 * Depositing is public: a wallet is seen sending collateral in. Everything after that is not.
 * A withdrawal is submitted by our relayer, and the *recipient* is a private input folded into the
 * proof's `context`. The pool checks that `context` against `keccak256(withdrawal, scope)`, so the
 * relayer cannot redirect a payout, and nothing on chain ties the recipient back to the depositor
 * beyond "both touched the same pool".
 *
 * For Numera that recipient is a market execution account, which is why a bet is unlinkable: the
 * account is funded out of the anonymity set rather than out of the trader's wallet.
 *
 * ## What is deliberately absent
 *
 * No fee accrual, no asset registry, no upgradeability. The pool is immutable once deployed and
 * the collateral is fixed at construction. An upgradeable contract holding a shielded pool's funds
 * is a trust assumption that would undo most of the point.
 */
contract NumeraPoolEntrypoint is IPoolEntrypoint, AccessControl, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;
    // ProofLib reads the public signals out of the flat `pubSignals` array by index. Its helpers
    // take `memory`, which is why `relay` does too.
    using ProofLib for ProofLib.WithdrawProof;

    /**
     * @notice May publish a new association-set root.
     * @dev Held by the backend's ASP service. On this deployment the set approves every deposit, so
     *      the role's power is to keep the root *current* rather than to censor: a stale root
     *      silently blocks every withdrawal, since the pool insists a proof be against the latest.
     */
    bytes32 public constant ASP_POSTMAN_ROLE = keccak256("ASP_POSTMAN_ROLE");

    /// @notice May submit withdrawal proofs on a trader's behalf. Held by the gas relayer.
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    /**
     * @notice A gasless account's signed instruction to shield its balance.
     * @param owner The account whose collateral moves. Signs this struct.
     * @param value Collateral to shield, in base units.
     * @param precommitment `Poseidon(nullifier, secret)` for the note being created. Signed, so a
     *        submitter cannot substitute a note of their own.
     * @param deadline Unix seconds after which the instruction is dead.
     */
    struct ShieldRequest {
        address owner;
        uint256 value;
        uint256 precommitment;
        uint256 deadline;
    }

    bytes32 private constant SHIELD_TYPEHASH =
        keccak256("Shield(address owner,uint256 value,uint256 precommitment,uint256 nonce,uint256 deadline)");

    /// @notice Sequential per-owner nonce for {depositFor}. Separate from the collateral's own.
    mapping(address owner => uint256 nonce) public shieldNonces;

    /// @notice The pool this entrypoint speaks for. Immutable: a swappable pool is a rug.
    IPrivacyPool public immutable POOL;

    /// @notice The only collateral this pool accepts.
    IERC20 public immutable ASSET;

    /// @inheritdoc IPoolEntrypoint
    uint256 public latestRoot;

    /// @notice How many roots have been published. Lets the indexer detect a missed update.
    uint256 public rootIndex;

    /// @notice Emitted whenever the association set advances.
    event RootUpdated(uint256 indexed index, uint256 root);
    /**
     * @notice A shielded withdrawal was paid out.
     * @dev Deliberately does NOT name the recipient. It is in the calldata either way, but an
     *      indexed event field is an invitation to build the very join this pool exists to prevent.
     */
    event Relayed(uint256 indexed nullifierHash, uint256 value);

    error RootUnchanged();
    error RootZero();
    error RecipientMismatch(address encoded, address paid);
    error ShieldExpired(uint256 deadline);
    error InvalidShieldSignature();

    /**
     * @param admin Receives `DEFAULT_ADMIN_ROLE`, and grants the other two.
     * @param pool The privacy pool. Must have been constructed with this contract as its entrypoint.
     * @param asset The pool's collateral.
     */
    constructor(address admin, IPrivacyPool pool, IERC20 asset) EIP712("Numera Shielded Pool", "1") {
        if (admin == address(0) || address(pool) == address(0) || address(asset) == address(0)) {
            revert ZeroAddress();
        }
        POOL = pool;
        ASSET = asset;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ---------------------------------------------------------------- association set

    /**
     * @notice Publish a new association-set root.
     * @dev Monotonic only in the sense that it must change: replaying an old root is allowed and is
     *      the intended recovery if a bad set is ever published, but a no-op update is rejected so
     *      a stuck ASP service is visible rather than silently reassuring.
     */
    function updateRoot(uint256 root) external onlyRole(ASP_POSTMAN_ROLE) returns (uint256 index) {
        if (root == 0) revert RootZero();
        if (root == latestRoot) revert RootUnchanged();
        latestRoot = root;
        index = ++rootIndex;
        emit RootUpdated(index, root);
    }

    // ---------------------------------------------------------------- in

    /**
     * @notice Deposit collateral into the shielded pool.
     * @dev Public by nature: the depositing wallet, the amount and the block are all visible. What
     *      is hidden is everything afterwards, because the note this creates can only be spent by
     *      whoever knows the preimage of `precommitment`.
     *
     *      Callable by anyone, and that matters for the return leg: a market execution account
     *      sweeping its balance back into the pool calls this directly (relayed for gas), and the
     *      note it creates belongs to the trader, not to the account.
     * @param value Collateral to shield, in base units.
     * @param precommitment `Poseidon(nullifier, secret)`, computed in the browser.
     * @return commitment The note inserted into the state tree.
     */
    function deposit(uint256 value, uint256 precommitment) external nonReentrant returns (uint256 commitment) {
        commitment = _shield(msg.sender, value, precommitment);
    }

    /**
     * @notice Deposit on behalf of an account that holds no gas, authorised by its signature.
     * @dev This is the return leg, and the reason it needs its own entry point is worth stating.
     *
     *      A market execution account holds zero native balance for its entire life — see
     *      `NumeraForwarder` for why sending it gas would retroactively deanonymise every position
     *      it ever held. So when a market settles and the account is holding collateral, it cannot
     *      call {deposit}: it cannot pay for the transaction, and it cannot even `approve` first.
     *
     *      ERC-2771 would be the obvious answer and is the wrong one here. `deposit` pulls with
     *      `transferFrom(msg.sender)`, so under a forwarder the pull would come from the *forwarder*
     *      rather than the account, and making this contract trust a mutable forwarder address is a
     *      larger trust assumption than the whole pool is worth.
     *
     *      Instead the authorisation is a signature that names the note. `precommitment` is inside
     *      the signed struct, which is the property that makes this permissionless-safe: a submitter
     *      cannot redirect the deposit into a note they control, because changing the precommitment
     *      invalidates the signature. Anyone may pay the gas; only the owner decides where the value
     *      lands. Our relayer is simply the one who usually does.
     * @param req The signed intent. `owner` is the account whose balance moves.
     * @param signature `owner`'s EIP-712 signature over `req`. EOA or ERC-1271.
     */
    function depositFor(ShieldRequest calldata req, bytes calldata signature)
        external
        nonReentrant
        returns (uint256 commitment)
    {
        _authorise(req, signature);
        commitment = _shield(req.owner, req.value, req.precommitment);
    }

    /**
     * @notice {depositFor}, with the allowance granted by signature in the same transaction.
     * @dev The account cannot `approve`, so the allowance has to arrive as an EIP-2612 permit. Two
     *      signatures rather than one, and they cost nothing: the market account's key is already in
     *      the browser's memory, so neither is a prompt the user sees.
     *
     *      The permit is submitted inside a `try` because it is front-runnable by nature — a permit
     *      is a bearer authorisation, and anybody watching the mempool can land it first. That is
     *      harmless (it grants exactly the allowance we were about to grant) but it would revert the
     *      whole deposit on a consumed nonce, which reads to the user as a failed withdrawal. If the
     *      allowance is already there, the transfer below succeeds and the permit was never needed.
     */
    function depositForWithPermit(
        ShieldRequest calldata req,
        bytes calldata signature,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 commitment) {
        _authorise(req, signature);
        try IERC20Permit(address(ASSET)).permit(req.owner, address(this), req.value, permitDeadline, v, r, s) {}
        catch {}
        commitment = _shield(req.owner, req.value, req.precommitment);
    }

    /// @dev Consumes the nonce, so a replay of the same signed request fails on the second attempt.
    function _authorise(ShieldRequest calldata req, bytes calldata signature) private {
        if (req.owner == address(0)) revert ZeroAddress();
        if (block.timestamp > req.deadline) revert ShieldExpired(req.deadline);

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    SHIELD_TYPEHASH, req.owner, req.value, req.precommitment, shieldNonces[req.owner]++, req.deadline
                )
            )
        );
        if (!SignatureChecker.isValidSignatureNow(req.owner, digest, signature)) {
            revert InvalidShieldSignature();
        }
    }

    function _shield(address depositor, uint256 value, uint256 precommitment) private returns (uint256 commitment) {
        if (value == 0) revert AmountZero();

        ASSET.safeTransferFrom(depositor, address(this), value);
        // The pool pulls from us, so it needs standing permission for exactly this transfer.
        ASSET.forceApprove(address(POOL), value);

        commitment = POOL.deposit(depositor, value, precommitment);
    }

    // ---------------------------------------------------------------- out

    /**
     * @notice Submit a withdrawal proof and forward the proceeds to the recipient it names.
     * @dev Two-hop by necessity. `PrivacyPool.withdraw` pays `withdrawal.processooor`, which must
     *      equal `msg.sender` — so the pool pays *this contract*, and this contract pays the
     *      recipient encoded in `withdrawal.data`. That encoding is inside the proof's `context`,
     *      which the pool re-derives and compares, so a relayer that tampers with the recipient
     *      produces a proof the pool rejects rather than a payout it redirects.
     *
     *      Restricted to `RELAYER_ROLE`. Not for privacy — the proof is self-contained and anyone
     *      holding it could submit it — but because a sponsored transaction is a cost, and an open
     *      endpoint that spends our gas is one somebody will spend for us.
     * @param withdrawal The withdrawal, whose `data` is `abi.encode(address recipient)`.
     * @param proof The Groth16 withdrawal proof.
     */
    function relay(IPrivacyPool.Withdrawal memory withdrawal, ProofLib.WithdrawProof memory proof)
        external
        onlyRole(RELAYER_ROLE)
        nonReentrant
    {
        address recipient = abi.decode(withdrawal.data, (address));
        if (recipient == address(0)) revert ZeroAddress();
        // The pool pays whoever it is told is processing, and that has to be us for the forward
        // below to happen at all. Checked here so a malformed request fails on a cheap comparison
        // rather than deep inside proof verification.
        if (withdrawal.processooor != address(this)) {
            revert RecipientMismatch(withdrawal.processooor, address(this));
        }

        uint256 value = proof.withdrawnValue();
        POOL.withdraw(withdrawal, proof);
        ASSET.safeTransfer(recipient, value);

        emit Relayed(proof.existingNullifierHash(), value);
    }

    /**
     * @notice The scope every proof for this pool is bound to.
     * @dev Exposed so the client can compute `context` without a second contract read.
     */
    function scope() external view returns (uint256) {
        return POOL.SCOPE();
    }
}
