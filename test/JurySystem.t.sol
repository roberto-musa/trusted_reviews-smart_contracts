// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "../lib/forge-std/src/Test.sol";
import "../src/DisputeManager.sol";
import "../src/JurySystem.sol";

/// @dev Mock ERC20 minimale per DisputeManager
interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

contract MockERC20 is IERC20Minimal {
    string public name = "Mock Token";
    string public symbol = "MCK";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount)
        external
        returns (bool)
    {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        require(to != address(0), "Invalid to");

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount)
        external
        returns (bool)
    {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(to != address(0), "Invalid to");

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract JurySystemTest is Test {
    MockERC20 internal token;
    DisputeManager internal disputeManager;
    JurySystem internal jurySystem;

    address internal business  = address(0xB1);
    address internal user      = address(0xB2);
    address internal treasury  = address(0xB3);
    // address internal ownerDm   = address(0xD1); // owner DisputeManager
    address internal ownerJury = address(0xE1); // owner JurySystem

    address internal juror1 = address(0xA1);
    address internal juror2 = address(0xA2);
    address internal juror3 = address(0xA3);
    address internal juror4 = address(0xA4);
    address internal juror5 = address(0xA5);


    uint256 internal businessStakeAmount = 20 ether;
    uint256 internal userStakeAmount     = 5 ether;
    uint256 internal treasuryFeeBps      = 1_000; // 10%

    uint256 internal minReputationForJuror     = 10;
    uint256 internal maxActiveDisputesPerJuror = 3;
    uint8   internal jurorsPerDispute          = 5;

    uint256 internal rewardMajority = 2;
    uint256 internal slashMinority  = 1;
    uint256 internal slashNoVote    = 3;

    function setUp() public {
        token = new MockERC20();

        // Mint iniziale a business e user
        token.mint(business, 100 ether);
        token.mint(user, 100 ether);

        // Deploy DisputeManager
        // vm.prank(ownerDm);
        vm.prank(ownerJury);
        disputeManager = new DisputeManager(
            IERC20(address(token)),
            treasury,
            businessStakeAmount,
            userStakeAmount,
            treasuryFeeBps
        );

        // Approve per gli stake
        vm.startPrank(business);
        token.approve(address(disputeManager), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user);
        token.approve(address(disputeManager), type(uint256).max);
        vm.stopPrank();

        // Deploy JurySystem
        jurySystem = new JurySystem(
            disputeManager,
            minReputationForJuror,
            maxActiveDisputesPerJuror,
            jurorsPerDispute,
            rewardMajority,
            slashMinority,
            slashNoVote,
            ownerJury
        );

        // Trasferisci la ownership del DisputeManager al contratto JurySystem per il test
        vm.prank(ownerJury);
        disputeManager.transferOwnership(address(jurySystem));

        // Registra i giurati con reputazione iniziale
        vm.startPrank(ownerJury);
        jurySystem.registerJuror(juror1, 20);
        jurySystem.registerJuror(juror2, 20);
        jurySystem.registerJuror(juror3, 20);
        jurySystem.registerJuror(juror4, 20);
        jurySystem.registerJuror(juror5, 20);
        vm.stopPrank();
    }

    function test_AssignJury_Success() public {
        // Arrange: apri e difendi una disputa (così è pronta per la giuria)
        uint256 reviewId = 1;
        vm.prank(business);
        disputeManager.openDispute(reviewId, user);

        vm.prank(user);
        disputeManager.defendDispute(0);

        address[] memory juryList = new address[](5);
        juryList[0] = juror1;
        juryList[1] = juror2;
        juryList[2] = juror3;
        juryList[3] = juror4;
        juryList[4] = juror5;

        vm.prank(ownerJury);
        vm.expectEmit(true, true, false, true);
        emit JuryAssigned(0, juryList);
        jurySystem.assignJury(0, juryList);

        // Lettura stato giuria
        (
            JurySystem.JuryState state,
            address[] memory assignedJurors,
            uint256 votesB,
            uint256 votesU
        ) = jurySystem.getJuryForDispute(0);

        assertEq(uint8(state), uint8(JurySystem.JuryState.Voting));
        assertEq(assignedJurors.length, 5);
        assertEq(assignedJurors[0], juror1);
        assertEq(votesB, 0);
        assertEq(votesU, 0);

        // Verifica activeDisputes incrementato
        (bool registered,,) = _getJurorInfo(juror1);
        (, uint256 rep1, uint256 active1) = _getJurorInfo(juror1);
        assertTrue(registered);
        assertEq(rep1, 20);
        assertEq(active1, 1);
    }

    function test_AssignJury_Revert_IfJurorNotEligible() public {
        // Imposta reputazione troppo bassa per juror5
        vm.prank(ownerJury);
        jurySystem.updateJurorReputation(juror5, 1);

        uint256 reviewId = 1;
        vm.prank(business);
        disputeManager.openDispute(reviewId, user);

        vm.prank(user);
        disputeManager.defendDispute(0);

        address[] memory juryList = new address[](5);
        juryList[0] = juror1;
        juryList[1] = juror2;
        juryList[2] = juror3;
        juryList[3] = juror4;
        juryList[4] = juror5; // reputazione < soglia

        vm.prank(ownerJury);
        vm.expectRevert(JurySystem.JurorNotEligible.selector);
        jurySystem.assignJury(0, juryList);
    }

    
    function test_SubmitVote_And_Finalize_MajorityBusiness_RewardsAndSlashes() public {
        // Arrange: disputa pronta e giuria assegnata
        uint256 reviewId = 1;

        vm.prank(business);
        disputeManager.openDispute(reviewId, user);

        vm.prank(user);
        disputeManager.defendDispute(0);

        address[] memory juryList = new address[](5);
        juryList[0] = juror1;
        juryList[1] = juror2;
        juryList[2] = juror3;
        juryList[3] = juror4;
        juryList[4] = juror5;

        vm.prank(ownerJury);
        jurySystem.assignJury(0, juryList);

        // Reputazioni iniziali
        (, uint256 rep1Before, uint256 act1Before) = _getJurorInfo(juror1);
        (, uint256 rep2Before, ) = _getJurorInfo(juror2);
        (, uint256 rep3Before, ) = _getJurorInfo(juror3);
        (, uint256 rep4Before, ) = _getJurorInfo(juror4);
        (, uint256 rep5Before, ) = _getJurorInfo(juror5);

        // Voti:
        // - 3 giurati per Business (maggioranza)
        // - 1 giurato per User (minoranza)
        // - 1 giurato non vota (no_vote)
        vm.prank(juror1);
        jurySystem.submitVote(0, DisputeManager.Party.Business);

        vm.prank(juror2);
        jurySystem.submitVote(0, DisputeManager.Party.Business);

        vm.prank(juror3);
        jurySystem.submitVote(0, DisputeManager.Party.Business);

        vm.prank(juror4);
        jurySystem.submitVote(0, DisputeManager.Party.User);

        // juror5 non vota

        // Saldi prima della risoluzione (per verificare chiamata al DisputeManager)
        uint256 businessBalanceBefore = token.balanceOf(business);
        uint256 userBalanceBefore     = token.balanceOf(user);
        uint256 treasuryBalanceBefore = token.balanceOf(treasury);

        uint256 totalStake = businessStakeAmount + userStakeAmount;
        uint256 loserStake = userStakeAmount; // utente perde
        uint256 expectedFeeToTreasury = (loserStake * treasuryFeeBps) / 10_000;
        uint256 expectedAmountToWinner = totalStake - expectedFeeToTreasury;

        // Act: ownerJury finalizza -> decide Business vincitore e chiama DisputeManager
        vm.prank(ownerJury);
        vm.expectEmit(true, false, false, true);
        emit JuryDecision(
            0,
            DisputeManager.Party.Business,
            3,
            1
        );
        jurySystem.finalizeJuryDecision(0);

        // Assert: reward/slashing reputazione
        (, uint256 rep1After, uint256 act1After) = _getJurorInfo(juror1);
        (, uint256 rep2After, ) = _getJurorInfo(juror2);
        (, uint256 rep3After, ) = _getJurorInfo(juror3);
        (, uint256 rep4After, ) = _getJurorInfo(juror4);
        (, uint256 rep5After, ) = _getJurorInfo(juror5);

        // juror1,2,3 in maggioranza (+rewardMajority)
        assertEq(rep1After, rep1Before + rewardMajority);
        assertEq(rep2After, rep2Before + rewardMajority);
        assertEq(rep3After, rep3Before + rewardMajority);

        // juror4 in minoranza (-slashMinority)
        assertEq(rep4After, rep4Before - slashMinority);

        // juror5 non vota (-slashNoVote)
        assertEq(rep5After, rep5Before - slashNoVote);

        // activeDisputes decrementato
        assertEq(act1After, act1Before - 1);

        // Verifica che DisputeManager abbia applicato la decisione (Business vincitore)
        uint256 businessBalanceAfter = token.balanceOf(business);
        uint256 userBalanceAfter     = token.balanceOf(user);
        uint256 treasuryBalanceAfter = token.balanceOf(treasury);

        // assertEq(userBalanceAfter, userBalanceBefore - userStakeAmount);
        // L'utente NON cambia saldo tra prima e dopo la risoluzione
        assertEq(userBalanceAfter, userBalanceBefore);
        assertEq(
            businessBalanceAfter,
            businessBalanceBefore + expectedAmountToWinner
        );
        assertEq(
            treasuryBalanceAfter - treasuryBalanceBefore,
            expectedFeeToTreasury
        );
        assertEq(token.balanceOf(address(disputeManager)), 0);

        // Stato disputa
        (
            ,
            ,
            ,
            ,
            uint256 businessStake,
            uint256 userStake,
            DisputeManager.DisputeState state,
            DisputeManager.Party winner
        ) = disputeManager.disputes(0);

        assertEq(uint8(state), uint8(DisputeManager.DisputeState.Resolved));
        assertEq(uint8(winner), uint8(DisputeManager.Party.Business));
        assertEq(businessStake, businessStakeAmount);
        assertEq(userStake, userStakeAmount);
    }
    

    /*
    function test_SubmitVote_And_Finalize_MajorityBusiness_RewardsAndSlashes() public {
        // Arrange: disputa pronta e giuria assegnata
        // Questa versione di test è semplificata in quanto la precedente generava un errore
        // “Stack too deep” a causa dell'alto numero di variabili locali. 
        // Il compilatore di Solidity 0.8.30 per i test senza via-ir non supporta bene questo caso.

        uint256 reviewId = 1;

        vm.prank(business);
        disputeManager.openDispute(reviewId, user);

        vm.prank(user);
        disputeManager.defendDispute(0);

        address[] memory juryList = new address[](5);
        juryList[0] = juror1;
        juryList[1] = juror2;
        juryList[2] = juror3;
        juryList[3] = juror4;
        juryList[4] = juror5;

        vm.prank(ownerJury);
        jurySystem.assignJury(0, juryList);

        // Reputazioni iniziali (leggiamo direttamente per ogni giurato, senza troppi temporanei)
        (, uint256 rep1Before,) = jurySystem.jurors(juror1);
        (, uint256 rep2Before,) = jurySystem.jurors(juror2);
        (, uint256 rep3Before,) = jurySystem.jurors(juror3);
        (, uint256 rep4Before,) = jurySystem.jurors(juror4);
        (, uint256 rep5Before,) = jurySystem.jurors(juror5);

        // Voti: 3 per Business, 1 per User, 1 non vota
        vm.prank(juror1);
        jurySystem.submitVote(0, DisputeManager.Party.Business);

        vm.prank(juror2);
        jurySystem.submitVote(0, DisputeManager.Party.Business);

        vm.prank(juror3);
        jurySystem.submitVote(0, DisputeManager.Party.Business);

        vm.prank(juror4);
        jurySystem.submitVote(0, DisputeManager.Party.User);
        // juror5 non vota

        // Saldi prima della risoluzione
        uint256 businessBalanceBefore = token.balanceOf(business);
        uint256 userBalanceBefore     = token.balanceOf(user);
        uint256 treasuryBalanceBefore = token.balanceOf(treasury);

        // Attese per la distribuzione economica
        uint256 totalStake = businessStakeAmount + userStakeAmount;
        uint256 loserStake = userStakeAmount; // utente perde
        uint256 expectedFeeToTreasury = (loserStake * treasuryFeeBps) / 10_000;
        uint256 expectedAmountToWinner = totalStake - expectedFeeToTreasury;

        // Act: finalizza -> Business vincitore
        vm.prank(ownerJury);
        vm.expectEmit(true, false, false, true);
        emit JuryDecision(
            0,
            DisputeManager.Party.Business,
            3,
            1
        );
        jurySystem.finalizeJuryDecision(0);

        // Reputazioni dopo
        (, uint256 rep1After, uint256 act1After) = jurySystem.jurors(juror1);
        (, uint256 rep2After,) = jurySystem.jurors(juror2);
        (, uint256 rep3After,) = jurySystem.jurors(juror3);
        (, uint256 rep4After,) = jurySystem.jurors(juror4);
        (, uint256 rep5After,) = jurySystem.jurors(juror5);

        // Majority: juror1,2,3
        assertEq(rep1After, rep1Before + rewardMajority);
        assertEq(rep2After, rep2Before + rewardMajority);
        assertEq(rep3After, rep3Before + rewardMajority);

        // Minority: juror4
        assertEq(rep4After, rep4Before - slashMinority);

        // No vote: juror5
        assertEq(rep5After, rep5Before - slashNoVote);

        // activeDisputes decrementato per juror1 (e analogamente per gli altri)
        assertEq(act1After, 0);

        // Verifica distribuzione economica
        uint256 businessBalanceAfter = token.balanceOf(business);
        uint256 userBalanceAfter     = token.balanceOf(user);
        uint256 treasuryBalanceAfter = token.balanceOf(treasury);

        assertEq(userBalanceAfter, userBalanceBefore - userStakeAmount);
        assertEq(
            businessBalanceAfter,
            businessBalanceBefore + expectedAmountToWinner
        );
        assertEq(
            treasuryBalanceAfter - treasuryBalanceBefore,
            expectedFeeToTreasury
        );
        assertEq(token.balanceOf(address(disputeManager)), 0);

        // Stato disputa
        (
            ,
            ,
            ,
            ,
            uint256 businessStake,
            uint256 userStake,
            DisputeManager.DisputeState state,
            DisputeManager.Party winner
        ) = disputeManager.disputes(0);

        assertEq(uint8(state), uint8(DisputeManager.DisputeState.Resolved));
        assertEq(uint8(winner), uint8(DisputeManager.Party.Business));
        assertEq(businessStake, businessStakeAmount);
        assertEq(userStake, userStakeAmount);
    }
    */

    function test_Finalize_Revert_OnTie() public {
        uint256 reviewId = 1;
        vm.prank(business);
        disputeManager.openDispute(reviewId, user);
        vm.prank(user);
        disputeManager.defendDispute(0);

        address[] memory juryList = new address[](5);
        juryList[0] = juror1;
        juryList[1] = juror2;
        juryList[2] = juror3;
        juryList[3] = juror4;
        juryList[4] = juror5;

        vm.prank(ownerJury);
        jurySystem.assignJury(0, juryList);

        // 2 voti per Business, 2 per User, 1 non vota -> pareggio
        vm.prank(juror1);
        jurySystem.submitVote(0, DisputeManager.Party.Business);

        vm.prank(juror2);
        jurySystem.submitVote(0, DisputeManager.Party.Business);

        vm.prank(juror3);
        jurySystem.submitVote(0, DisputeManager.Party.User);

        vm.prank(juror4);
        jurySystem.submitVote(0, DisputeManager.Party.User);

        vm.prank(ownerJury);
        vm.expectRevert(JurySystem.NoMajority.selector);
        jurySystem.finalizeJuryDecision(0);
    }

    // ---- Helpers ----

    function _getJurorInfo(address j)
        internal
        view
        returns (bool registered, uint256 reputation, uint256 activeDisputes)
    {
        JurySystem.JurorInfo memory info;
        // non si può fare struct copy directly perché JurorInfo è internal;
        // si accede via getter pubblico generato dal compilatore non essendoci mapping pubblico.
        // Poiché in JurySystem è `mapping(address => JurorInfo) public jurors;`
        // il compilatore genera una funzione:
        // jurors(address) returns (bool, uint256, uint256)
        (registered, reputation, activeDisputes) = jurySystem.jurors(j);
    }

    // Eventi re-dichiarati per vm.expectEmit
    event JuryAssigned(uint256 indexed disputeId, address[] jurors);
    event JuryDecision(
        uint256 indexed disputeId,
        DisputeManager.Party winner,
        uint256 votesForBusiness,
        uint256 votesForUser
    );
}
