// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Usa Test da forge-std
import {Test} from "../lib/forge-std/src/Test.sol";
import {DisputeManager, IERC20} from "../src/DisputeManager.sol";

/// @dev Interfaccia minima coerente con quella usata in DisputeManager
interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

/// @dev Mock ERC20 che implementa l'interfaccia minima usata dal contratto
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

contract DisputeManagerTest is Test {
    MockERC20 internal token;
    DisputeManager internal disputeManager;

    address internal business = address(0xB1);
    address internal user = address(0xB2);
    address internal treasury = address(0xB3);
    address internal owner = address(0xB4);

    uint256 internal businessStakeAmount = 20 ether;
    uint256 internal userStakeAmount = 5 ether;
    uint256 internal treasuryFeeBps = 1_000; // 10% sullo stake perdente

    function setUp() public {
        token = new MockERC20();

        // Mint iniziale a business e user
        token.mint(business, 100 ether);
        token.mint(user, 100 ether);

        // Deploy del DisputeManager con owner esplicito
        vm.prank(owner);
        disputeManager = new DisputeManager(
            IERC20(address(token)),
            treasury,
            businessStakeAmount,
            userStakeAmount,
            treasuryFeeBps
        );

        // Approve iniziali per permettere transferFrom
        vm.startPrank(business);
        token.approve(address(disputeManager), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user);
        token.approve(address(disputeManager), type(uint256).max);
        vm.stopPrank();
    }

    function test_OpenDispute_Success() public {
        uint256 reviewId = 1;

        uint256 businessBalanceBefore = token.balanceOf(business);

        vm.prank(business);
        vm.expectEmit(true, true, true, true);
        emit DisputeOpened(0, reviewId, business, user, businessStakeAmount);
        disputeManager.openDispute(reviewId, user);

        // Verifica stato disputa
        (
            uint256 id,
            uint256 storedReviewId,
            address storedBusiness,
            address storedUser,
            uint256 businessStake,
            uint256 userStake,
            DisputeManager.DisputeState state,
            DisputeManager.Party winner
        ) = disputeManager.disputes(0);

        assertEq(id, 0);
        assertEq(storedReviewId, reviewId);
        assertEq(storedBusiness, business);
        assertEq(storedUser, user);
        assertEq(businessStake, businessStakeAmount);
        assertEq(userStake, 0);
        assertEq(uint8(state), uint8(DisputeManager.DisputeState.AwaitingDefense));
        assertEq(uint8(winner), uint8(DisputeManager.Party.None));

        // Verifica saldo business diminuito dello stake
        uint256 businessBalanceAfter = token.balanceOf(business);
        assertEq(
            businessBalanceBefore - businessBalanceAfter,
            businessStakeAmount
        );

        // Verifica che il contratto abbia ricevuto lo stake
        assertEq(token.balanceOf(address(disputeManager)), businessStakeAmount);
    }

    function test_DefendDispute_Success() public {
        // Arrange: apertura disputa
        uint256 reviewId = 1;
        vm.prank(business);
        disputeManager.openDispute(reviewId, user);

        uint256 userBalanceBefore = token.balanceOf(user);

        // Act: difesa dell'utente
        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit DisputeDefended(0, user, userStakeAmount);
        disputeManager.defendDispute(0);

        // Assert: verifica stato
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

        assertEq(businessStake, businessStakeAmount);
        assertEq(userStake, userStakeAmount);
        assertEq(uint8(state), uint8(DisputeManager.DisputeState.ReadyForResolution));
        assertEq(uint8(winner), uint8(DisputeManager.Party.None));

        // Verifica saldo utente diminuito
        uint256 userBalanceAfter = token.balanceOf(user);
        assertEq(
            userBalanceBefore - userBalanceAfter,
            userStakeAmount
        );

        // Il contratto ha entrambi gli stake
        assertEq(
            token.balanceOf(address(disputeManager)),
            businessStakeAmount + userStakeAmount
        );
    }

    function test_DefendDispute_Revert_IfNotUser() public {
        uint256 reviewId = 1;
        vm.prank(business);
        disputeManager.openDispute(reviewId, user);

        vm.prank(business);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.NotUser.selector));
        disputeManager.defendDispute(0);
    }

    function test_DefendDispute_Revert_WrongState() public {
        uint256 reviewId = 1;
        vm.prank(business);
        disputeManager.openDispute(reviewId, user);

        // Prima difesa ok
        vm.prank(user);
        disputeManager.defendDispute(0);

        // Seconda difesa deve fallire per stato != AwaitingDefense
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.InvalidState.selector));
        disputeManager.defendDispute(0);
    }

    function test_ResolveDispute_WinnerBusiness_Distribution() public {
        // Arrange: apertura + difesa
        uint256 reviewId = 1;

        vm.prank(business);
        disputeManager.openDispute(reviewId, user);

        vm.prank(user);
        disputeManager.defendDispute(0);

        uint256 businessBalanceBefore = token.balanceOf(business);
        uint256 userBalanceBefore = token.balanceOf(user);
        uint256 treasuryBalanceBefore = token.balanceOf(treasury);

        uint256 totalStake = businessStakeAmount + userStakeAmount;
        uint256 loserStake = userStakeAmount; // utente perde
        uint256 expectedFeeToTreasury = (loserStake * treasuryFeeBps) / 10_000;
        uint256 expectedAmountToWinner = totalStake - expectedFeeToTreasury;

        // Act: owner risolve a favore del business
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit DisputeResolved(
            0,
            DisputeManager.Party.Business,
            expectedAmountToWinner,
            expectedFeeToTreasury
        );
        disputeManager.resolveDispute(0, DisputeManager.Party.Business);

        // Assert: saldi
        uint256 businessBalanceAfter = token.balanceOf(business);
        uint256 userBalanceAfter = token.balanceOf(user);
        uint256 treasuryBalanceAfter = token.balanceOf(treasury);

        // L'utente ha perso il suo stake (già trasferito al contratto)
        assertEq(userBalanceAfter, userBalanceBefore);

        // Il business ha saldo aumentato dell'importo vinto
        assertEq(
            businessBalanceAfter,
            businessBalanceBefore + expectedAmountToWinner
        );

        // Tesoreria ha ricevuto la fee
        assertEq(
            treasuryBalanceAfter - treasuryBalanceBefore,
            expectedFeeToTreasury
        );

        // Il contratto non deve più trattenere fondi relativi alla disputa
        assertEq(token.balanceOf(address(disputeManager)), 0);

        // Stato e winner
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

    function test_ResolveDispute_WinnerUser_Distribution() public {
        // Arrange: apertura + difesa
        uint256 reviewId = 1;

        vm.prank(business);
        disputeManager.openDispute(reviewId, user);

        vm.prank(user);
        disputeManager.defendDispute(0);

        uint256 businessBalanceBefore = token.balanceOf(business);
        uint256 userBalanceBefore = token.balanceOf(user);
        uint256 treasuryBalanceBefore = token.balanceOf(treasury);

        uint256 totalStake = businessStakeAmount + userStakeAmount;
        uint256 loserStake = businessStakeAmount; // business perde
        uint256 expectedFeeToTreasury = (loserStake * treasuryFeeBps) / 10_000;
        uint256 expectedAmountToWinner = totalStake - expectedFeeToTreasury;

        // Act: owner risolve a favore dell'utente
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit DisputeResolved(
            0,
            DisputeManager.Party.User,
            expectedAmountToWinner,
            expectedFeeToTreasury
        );
        disputeManager.resolveDispute(0, DisputeManager.Party.User);

        // Assert: saldi
        uint256 businessBalanceAfter = token.balanceOf(business);
        uint256 userBalanceAfter = token.balanceOf(user);
        uint256 treasuryBalanceAfter = token.balanceOf(treasury);

        // L'utente ha saldo iniziale (già dopo lo stake) + amountToWinner
        assertEq(
            userBalanceAfter,
            userBalanceBefore + expectedAmountToWinner
        );

        // Tesoreria ha ricevuto la fee
        assertEq(
            treasuryBalanceAfter - treasuryBalanceBefore,
            expectedFeeToTreasury
        );

        assertEq(token.balanceOf(address(disputeManager)), 0);
    }

    function test_ResolveDispute_Revert_IfNotOwner() public {
        uint256 reviewId = 1;
        vm.prank(business);
        disputeManager.openDispute(reviewId, user);
        vm.prank(user);
        disputeManager.defendDispute(0);

        vm.prank(business);
        vm.expectRevert(); // NotOwner
        disputeManager.resolveDispute(0, DisputeManager.Party.Business);
    }

    function test_CancelDispute_RefundBusiness() public {
        uint256 reviewId = 1;

        vm.prank(business);
        disputeManager.openDispute(reviewId, user);

        uint256 businessBalanceBefore = token.balanceOf(business);

        // Owner cancella la disputa prima della difesa dell'utente
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit DisputeCancelled(0);
        disputeManager.cancelDispute(0);

        uint256 businessBalanceAfter = token.balanceOf(business);
        assertEq(businessBalanceAfter, businessBalanceBefore + businessStakeAmount);

        assertEq(token.balanceOf(address(disputeManager)), 0);

        (
            ,
            ,
            ,
            ,
            ,
            ,
            DisputeManager.DisputeState state,
            DisputeManager.Party winner
        ) = disputeManager.disputes(0);

        assertEq(uint8(state), uint8(DisputeManager.DisputeState.Cancelled));
        assertEq(uint8(winner), uint8(DisputeManager.Party.None));
    }

    // Eventi re-dichiarati per vm.expectEmit
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
        DisputeManager.Party winner,
        uint256 amountToWinner,
        uint256 amountToTreasury
    );

    event DisputeCancelled(uint256 indexed disputeId);
}
