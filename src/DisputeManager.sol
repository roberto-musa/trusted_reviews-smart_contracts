// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract DisputeManager is Ownable {
    enum DisputeState {
        None,
        AwaitingDefense,  // Aperta dal business, in attesa dello stake dell'utente
        ReadyForResolution, // Entrambe le parti hanno messo lo stake
        Resolved,
        Cancelled
    }

    enum Party {
        None,
        Business,
        User
    }

    struct Dispute {
        uint256 id;
        uint256 reviewId;
        address business;
        address user;
        uint256 businessStake;
        uint256 userStake;
        DisputeState state;
        Party winner;
    }

    IERC20 public immutable stakeToken;
    address public treasury;

    uint256 public businessStakeAmount;
    uint256 public userStakeAmount;
    uint256 public treasuryFeeBps; // fee su stake perdente in basis points (es. 1000 = 10%)

    uint256 public nextDisputeId;
    mapping(uint256 => Dispute) public disputes;

    event DisputeOpened(
        uint256 indexed disputeId,
        uint256 indexed reviewId,
        address indexed business,
        address user,
        uint256 businessStake
    );

    event DisputeDefended(
        uint256 indexed disputeId,
        address indexed user,
        uint256 userStake
    );

    event DisputeResolved(
        uint256 indexed disputeId,
        Party winner,
        uint256 amountToWinner,
        uint256 amountToTreasury
    );

    event DisputeCancelled(uint256 indexed disputeId);

    error InvalidStakeAmounts();
    error InvalidTreasury();
    error InvalidParty();
    error InvalidState();
    error NotBusiness();
    error NotUser();
    error AlreadyDefended();

    constructor(
        IERC20 _stakeToken,
        address _treasury,
        uint256 _businessStakeAmount,
        uint256 _userStakeAmount,
        uint256 _treasuryFeeBps
    ) Ownable(msg.sender) {
        if (_treasury == address(0)) {
            revert InvalidTreasury();
        }
        if (_businessStakeAmount == 0 || _userStakeAmount == 0) {
            revert InvalidStakeAmounts();
        }
        require(_treasuryFeeBps <= 10_000, "Fee too high"); // max 100%

        stakeToken = _stakeToken;
        treasury = _treasury;
        businessStakeAmount = _businessStakeAmount;
        userStakeAmount = _userStakeAmount;
        treasuryFeeBps = _treasuryFeeBps;
    }

    // Permette di aggiornare i parametri economici in futuro (governance / owner).
    function setParams(
        uint256 _businessStakeAmount,
        uint256 _userStakeAmount,
        uint256 _treasuryFeeBps
    ) external onlyOwner {
        if (_businessStakeAmount == 0 || _userStakeAmount == 0) {
            revert InvalidStakeAmounts();
        }
        require(_treasuryFeeBps <= 10_000, "Fee too high");

        businessStakeAmount = _businessStakeAmount;
        userStakeAmount = _userStakeAmount;
        treasuryFeeBps = _treasuryFeeBps;
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) {
            revert InvalidTreasury();
        }
        treasury = _treasury;
    }

    /// @notice Il business apre una disputa su una review specifica
    /// @param reviewId ID della recensione contestata
    /// @param user Indirizzo dell'utente autore della recensione
    function openDispute(uint256 reviewId, address user) external {
        if (user == address(0)) {
            revert InvalidParty();
        }

        // Trasferisce lo stake dal business al contratto
        // Richiede che msg.sender abbia fatto approve verso questo contratto
        bool ok = stakeToken.transferFrom(
            msg.sender,
            address(this),
            businessStakeAmount
        );
        require(ok, "Token transfer failed");

        uint256 disputeId = nextDisputeId++;
        Dispute storage d = disputes[disputeId];

        d.id = disputeId;
        d.reviewId = reviewId;
        d.business = msg.sender;
        d.user = user;
        d.businessStake = businessStakeAmount;
        d.state = DisputeState.AwaitingDefense;
        d.winner = Party.None;

        emit DisputeOpened(disputeId, reviewId, msg.sender, user, businessStakeAmount);
    }

    /// @notice L'utente difende la propria recensione mettendo lo stake richiesto
    function defendDispute(uint256 disputeId) external {
        Dispute storage d = disputes[disputeId];

        if (d.state != DisputeState.AwaitingDefense) {
            revert InvalidState();
        }
        if (msg.sender != d.user) {
            revert NotUser();
        }
        if (d.userStake != 0) {
            revert AlreadyDefended();
        }

        bool ok = stakeToken.transferFrom(
            msg.sender,
            address(this),
            userStakeAmount
        );
        require(ok, "Token transfer failed");

        d.userStake = userStakeAmount;
        d.state = DisputeState.ReadyForResolution;

        emit DisputeDefended(disputeId, msg.sender, userStakeAmount);
    }

    /// @notice Risoluzione manuale (per ora gestita dall'owner, futura giuria on-chain)
    /// @param disputeId ID della disputa
    /// @param winner Parte vincitrice (Business o User)
    function resolveDispute(uint256 disputeId, Party winner) external onlyOwner {
        Dispute storage d = disputes[disputeId];

        if (d.state != DisputeState.ReadyForResolution) {
            revert InvalidState();
        }
        if (winner != Party.Business && winner != Party.User) {
            revert InvalidParty();
        }

        d.state = DisputeState.Resolved;
        d.winner = winner;

        uint256 totalStake = d.businessStake + d.userStake;
        uint256 loserStake = (winner == Party.Business) ? d.userStake : d.businessStake;

        uint256 feeToTreasury = (loserStake * treasuryFeeBps) / 10_000;
        uint256 amountToWinner = totalStake - feeToTreasury;

        // Payout
        if (winner == Party.Business) {
            _payout(d.business, amountToWinner);
        } else {
            _payout(d.user, amountToWinner);
        }

        if (feeToTreasury > 0) {
            _payout(treasury, feeToTreasury);
        }

        emit DisputeResolved(disputeId, winner, amountToWinner, feeToTreasury);
    }

    function cancelDispute(uint256 disputeId) external onlyOwner {
        Dispute storage d = disputes[disputeId];

        if (d.state != DisputeState.AwaitingDefense) {
            revert InvalidState();
        }

        d.state = DisputeState.Cancelled;

        // Restituisce lo stake al business
        if (d.businessStake > 0) {
            _payout(d.business, d.businessStake);
        }

        emit DisputeCancelled(disputeId);
    }

    function _payout(address to, uint256 amount) internal {
        if (amount == 0) return;
        bool ok = stakeToken.transfer(to, amount);
        require(ok, "Token transfer failed");
    }
}
