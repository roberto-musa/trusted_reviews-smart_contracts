// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DisputeManager.sol";

contract OwnableJury {
    address public owner;

    error NotOwner();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        require(initialOwner != address(0), "Invalid owner");
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }
    function _onlyOwner() internal {
        require(msg.sender == owner, "Not the owner");
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

/**
 * @title JurySystem
 * @notice Gestisce il pool dei giurati, il processo di voto e gli effetti
 *         economico/reputazionali (reward + slashing) previsti dal modello.
 */
contract JurySystem is OwnableJury {
    DisputeManager public immutable disputeManager;

    // Parametri configurabili di eleggibilità
    uint256 public minReputationForJuror;
    uint256 public maxActiveDisputesPerJuror;
    uint8 public jurorsPerDispute; // es. 5 o 7

    // Parametri per reward / slashing (in "punti reputazione")
    uint256 public rewardMajority;   // premio per giurati in maggioranza
    uint256 public slashMinority;    // penalità per giurati in minoranza
    uint256 public slashNoVote;      // penalità per giurati che non votano

    // Dati sul giurato
    struct JurorInfo {
        bool registered;
        uint256 reputation;      // reputazione interna, usata per soglie e incentivi
        uint256 activeDisputes;  // numero dispute in cui è attualmente coinvolto
    }

    // Stato di una giuria per una singola disputa
    enum JuryState {
        None,
        Voting,   // giuria assegnata, voti in corso
        Decided   // verdetto chiuso
    }

    struct JuryForDispute {
        JuryState state;
        address[] jurors;
        mapping(address => bool) hasVoted;
        mapping(address => DisputeManager.Party) voteOf;
        uint256 votesForBusiness;
        uint256 votesForUser;
    }

    mapping(address => JurorInfo) public jurors;          // info generali per indirizzo
    mapping(uint256 => JuryForDispute) private disputeJuries; // disputeId -> giuria

    // --- Eventi ---
    event JurorRegistered(address indexed juror, uint256 reputation);
    event JurorReputationUpdated(address indexed juror, uint256 newReputation);

    event JuryAssigned(uint256 indexed disputeId, address[] jurors);
    event VoteSubmitted(uint256 indexed disputeId, address indexed juror, DisputeManager.Party vote);

    event JuryDecision(
        uint256 indexed disputeId,
        DisputeManager.Party winner,
        uint256 votesForBusiness,
        uint256 votesForUser
    );

    event JurorRewarded(address indexed juror, uint256 amount);
    event JurorSlashed(address indexed juror, uint256 amount, string reason);

    // --- Errori ---
    error InvalidParams();
    error NotJuror();
    error JurorNotEligible();
    error MaxActiveDisputesReached();
    error InvalidJuryState();
    error AlreadyVoted();
    error NotPartOfJury();
    error NoMajority();
    error JurorsListMismatch();

    constructor(
        DisputeManager _disputeManager,
        uint256 _minReputationForJuror,
        uint256 _maxActiveDisputesPerJuror,
        uint8 _jurorsPerDispute,
        uint256 _rewardMajority,
        uint256 _slashMinority,
        uint256 _slashNoVote,
        address _owner
    ) OwnableJury(_owner) {
        if (
            address(_disputeManager) == address(0) ||
            _minReputationForJuror == 0 ||
            _maxActiveDisputesPerJuror == 0 ||
            _jurorsPerDispute == 0
        ) {
            revert InvalidParams();
        }

        disputeManager = _disputeManager;
        minReputationForJuror = _minReputationForJuror;
        maxActiveDisputesPerJuror = _maxActiveDisputesPerJuror;
        jurorsPerDispute = _jurorsPerDispute;

        rewardMajority = _rewardMajority;
        slashMinority = _slashMinority;
        slashNoVote = _slashNoVote;
    }

    // --- Configurazione ---

    function setParams(
        uint256 _minReputationForJuror,
        uint256 _maxActiveDisputesPerJuror,
        uint8 _jurorsPerDispute
    ) external onlyOwner {
        if (
            _minReputationForJuror == 0 ||
            _maxActiveDisputesPerJuror == 0 ||
            _jurorsPerDispute == 0
        ) {
            revert InvalidParams();
        }

        minReputationForJuror = _minReputationForJuror;
        maxActiveDisputesPerJuror = _maxActiveDisputesPerJuror;
        jurorsPerDispute = _jurorsPerDispute;
    }

    function setIncentiveParams(
        uint256 _rewardMajority,
        uint256 _slashMinority,
        uint256 _slashNoVote
    ) external onlyOwner {
        // consentiamo anche zero (nessun reward/slash), quindi niente check > 0
        rewardMajority = _rewardMajority;
        slashMinority = _slashMinority;
        slashNoVote = _slashNoVote;
    }

    // --- Gestione giurati ---

    function registerJuror(address juror, uint256 reputation) external onlyOwner {
        if (juror == address(0)) revert InvalidParams();

        JurorInfo storage info = jurors[juror];
        info.registered = true;
        info.reputation = reputation;

        emit JurorRegistered(juror, reputation);
    }

    function updateJurorReputation(address juror, uint256 newReputation) external onlyOwner {
        if (!jurors[juror].registered) revert NotJuror();
        jurors[juror].reputation = newReputation;
        emit JurorReputationUpdated(juror, newReputation);
    }

    // --- Assegnazione giuria ---

    function assignJury(uint256 disputeId, address[] calldata juryList) external onlyOwner {
        if (juryList.length != jurorsPerDispute) {
            revert JurorsListMismatch();
        }

        JuryForDispute storage jury = disputeJuries[disputeId];
        if (jury.state != JuryState.None) {
            revert InvalidJuryState();
        }

        // Verifica eleggibilità e aggiorna activeDisputes
        for (uint256 i = 0; i < juryList.length; i++) {
            address j = juryList[i];
            JurorInfo storage info = jurors[j];

            if (!info.registered) revert JurorNotEligible();
            if (info.reputation < minReputationForJuror) revert JurorNotEligible();
            if (info.activeDisputes >= maxActiveDisputesPerJuror) revert MaxActiveDisputesReached();

            info.activeDisputes += 1;
            jury.jurors.push(j);
        }

        jury.state = JuryState.Voting;

        emit JuryAssigned(disputeId, juryList);
    }

    // --- Voto giurati ---

    function submitVote(uint256 disputeId, DisputeManager.Party vote) external {
        JuryForDispute storage jury = disputeJuries[disputeId];

        if (jury.state != JuryState.Voting) {
            revert InvalidJuryState();
        }

        // Verifica che msg.sender sia nel set di giurati
        bool found = false;
        for (uint256 i = 0; i < jury.jurors.length; i++) {
            if (jury.jurors[i] == msg.sender) {
                found = true;
                break;
            }
        }
        if (!found) revert NotPartOfJury();

        if (jury.hasVoted[msg.sender]) {
            revert AlreadyVoted();
        }

        if (vote != DisputeManager.Party.Business && vote != DisputeManager.Party.User) {
            revert InvalidParams();
        }

        jury.hasVoted[msg.sender] = true;
        jury.voteOf[msg.sender] = vote;

        if (vote == DisputeManager.Party.Business) {
            jury.votesForBusiness += 1;
        } else {
            jury.votesForUser += 1;
        }

        emit VoteSubmitted(disputeId, msg.sender, vote);
    }

    // --- Chiusura verdetto + hook incentivi ---

    function finalizeJuryDecision(uint256 disputeId) external onlyOwner {
        JuryForDispute storage jury = disputeJuries[disputeId];

        if (jury.state != JuryState.Voting) {
            revert InvalidJuryState();
        }

        // Determina il vincitore
        DisputeManager.Party winner;
        if (jury.votesForBusiness > jury.votesForUser) {
            winner = DisputeManager.Party.Business;
        } else if (jury.votesForUser > jury.votesForBusiness) {
            winner = DisputeManager.Party.User;
        } else {
            // Pareggio: politica v1 -> revert; in v2 si può decidere fallback
            revert NoMajority();
        }

        jury.state = JuryState.Decided;

        // Applica reward / slashing su tutti i giurati
        for (uint256 i = 0; i < jury.jurors.length; i++) {
            address j = jury.jurors[i];
            JurorInfo storage info = jurors[j];

            // Decrementa sempre le dispute attive
            if (info.activeDisputes > 0) {
                info.activeDisputes -= 1;
            }

            // Caso 1: giurato non ha votato
            if (!jury.hasVoted[j]) {
                _applySlashNoVote(j);
                continue;
            }

            // Caso 2: ha votato; verifica se è in maggioranza o minoranza
            DisputeManager.Party v = jury.voteOf[j];

            if (v == winner) {
                _applyRewardMajority(j);
            } else {
                _applySlashMinority(j);
            }
        }

        emit JuryDecision(disputeId, winner, jury.votesForBusiness, jury.votesForUser);

        // Chiamata al DisputeManager per applicare il verdetto economico
        disputeManager.resolveDispute(disputeId, winner);
    }

    // --- Hook interni per incentivi ---

    function _applyRewardMajority(address juror) internal {
        if (rewardMajority == 0) return;

        JurorInfo storage info = jurors[juror];
        info.reputation += rewardMajority;

        emit JurorRewarded(juror, rewardMajority);
        emit JurorReputationUpdated(juror, info.reputation);
    }

    function _applySlashMinority(address juror) internal {
        if (slashMinority == 0) return;

        JurorInfo storage info = jurors[juror];

        // reputazione non va sotto zero
        uint256 amount = slashMinority;
        if (amount > info.reputation) {
            amount = info.reputation;
        }
        info.reputation -= amount;

        emit JurorSlashed(juror, amount, "minority_vote");
        emit JurorReputationUpdated(juror, info.reputation);
    }

    function _applySlashNoVote(address juror) internal {
        if (slashNoVote == 0) return;

        JurorInfo storage info = jurors[juror];

        uint256 amount = slashNoVote;
        if (amount > info.reputation) {
            amount = info.reputation;
        }
        info.reputation -= amount;

        emit JurorSlashed(juror, amount, "no_vote");
        emit JurorReputationUpdated(juror, info.reputation);
    }

    // --- Helpers di lettura ---

    function getJuryForDispute(uint256 disputeId)
        external
        view
        returns (
            JuryState state,
            address[] memory jurorsList,
            uint256 votesBusiness,
            uint256 votesUser
        )
    {
        JuryForDispute storage jury = disputeJuries[disputeId];
        state = jury.state;
        jurorsList = jury.jurors;
        votesBusiness = jury.votesForBusiness;
        votesUser = jury.votesForUser;
    }
}