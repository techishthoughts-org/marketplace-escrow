// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/EscrowMarketplace.sol";

contract EscrowMarketplaceTest is Test {
    EscrowMarketplace marketplace;
    address owner = address(0x10);
    address seller = address(2);
    address buyer = address(3);
    uint256 defaultFee = 250; // 2.5%

    event ItemListed(uint256 indexed itemId, address indexed seller, uint256 price);
    event ItemPurchased(uint256 indexed itemId, address indexed buyer, uint256 amount);
    event ItemDeliveryConfirmed(uint256 indexed itemId);
    event ItemRefunded(uint256 indexed itemId);
    event ItemDisputed(uint256 indexed itemId, address disputeInitiator);
    event DisputeResolved(uint256 indexed itemId, address winner);

    function setUp() public {
        vm.prank(owner);
        marketplace = new EscrowMarketplace(defaultFee);
    }

    function testInitialState() public {
        assertEq(marketplace.owner(), owner);
        assertEq(marketplace.feePercentage(), defaultFee);
        assertEq(marketplace.nextItemId(), 1);
    }

    function testListItem() public {
        vm.prank(seller);

        vm.expectEmit(true, true, false, true);
        emit ItemListed(1, seller, 1 ether);

        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);

        assertEq(itemId, 1);
        assertEq(marketplace.nextItemId(), 2);

        (
            uint256 id,
            string memory name,
            string memory description,
            uint256 price,
            address itemSeller,
            address itemBuyer,
            EscrowMarketplace.ItemStatus status,
            uint256 createdAt,
            uint256 completedAt
        ) = marketplace.getItem(itemId);

        assertEq(id, 1);
        assertEq(name, "Test Item");
        assertEq(description, "Test Description");
        assertEq(price, 1 ether);
        assertEq(itemSeller, seller);
        assertEq(itemBuyer, address(0));
        assertEq(uint256(status), uint256(EscrowMarketplace.ItemStatus.Listed));
        assertEq(completedAt, 0);
        assertGt(createdAt, 0);
    }

    function testPurchaseItem() public {
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);

        vm.prank(buyer);
        vm.expectEmit(true, true, false, true);
        emit ItemPurchased(itemId, buyer, 1 ether);

        vm.deal(buyer, 2 ether);
        marketplace.purchaseItem{value: 1 ether}(itemId);

        (,,,, address itemSeller, address itemBuyer, EscrowMarketplace.ItemStatus status,,) =
            marketplace.getItem(itemId);

        assertEq(itemSeller, seller);
        assertEq(itemBuyer, buyer);
        assertEq(uint256(status), uint256(EscrowMarketplace.ItemStatus.InEscrow));
    }

    function testPurchaseItemWithExcessPayment() public {
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);

        vm.deal(buyer, 2 ether);
        uint256 initialBalance = buyer.balance;

        vm.prank(buyer);
        marketplace.purchaseItem{value: 1.5 ether}(itemId);

        assertEq(buyer.balance, initialBalance - 1 ether);

        (,,,, address itemSeller, address itemBuyer, EscrowMarketplace.ItemStatus status,,) =
            marketplace.getItem(itemId);
        assertEq(itemBuyer, buyer);
        assertEq(uint256(status), uint256(EscrowMarketplace.ItemStatus.InEscrow));
    }

    function testConfirmDelivery() public {
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);

        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        marketplace.purchaseItem{value: 1 ether}(itemId);

        uint256 initialOwnerBalance = owner.balance;
        uint256 initialSellerBalance = seller.balance;

        uint256 feeAmount = (1 ether * defaultFee) / 10000; // 0.025 ether
        uint256 sellerAmount = 1 ether - feeAmount; // 0.975 ether

        vm.prank(buyer);
        vm.expectEmit(true, false, false, false);

        emit ItemDeliveryConfirmed(itemId);

        marketplace.confirmDelivery(itemId);

        assertEq(owner.balance, initialOwnerBalance + feeAmount);
        assertEq(seller.balance, initialSellerBalance + sellerAmount);
        (,,,,,, EscrowMarketplace.ItemStatus status,, uint256 completedAt) = marketplace.getItem(itemId);
        assertEq(uint256(status), uint256(EscrowMarketplace.ItemStatus.Completed));
        assertGt(completedAt, 0);
    }

    function testRequestRefund() public {
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        marketplace.purchaseItem{value: 1 ether}(itemId);

        vm.prank(buyer);
        vm.expectEmit(true, false, false, true);
        emit ItemDisputed(itemId, buyer);

        marketplace.requestRefund(itemId);

        (,,,,,, EscrowMarketplace.ItemStatus status,,) = marketplace.getItem(itemId);
        assertEq(uint256(status), uint256(EscrowMarketplace.ItemStatus.Disputed));
    }

    function testAgreeToRefund() public {
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        marketplace.purchaseItem{value: 1 ether}(itemId);

        vm.prank(buyer);
        marketplace.requestRefund(itemId);

        uint256 initialBuyerBalance = buyer.balance;

        vm.prank(seller);
        vm.expectEmit(true, false, false, false);
        emit ItemRefunded(itemId);

        marketplace.agreeToRefund(itemId);

        assertEq(buyer.balance, initialBuyerBalance + 1 ether);

        (,,,,,, EscrowMarketplace.ItemStatus status,,) = marketplace.getItem(itemId);
        assertEq(uint256(status), uint256(EscrowMarketplace.ItemStatus.Refunded));
    }

    function testResolveDisputeRefundToBuyer() public {
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        marketplace.purchaseItem{value: 1 ether}(itemId);

        vm.prank(buyer);
        marketplace.requestRefund(itemId);

        uint256 initialBuyerBalance = buyer.balance;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit DisputeResolved(itemId, buyer);

        marketplace.resolveDispute(itemId, true);

        assertEq(buyer.balance, initialBuyerBalance + 1 ether);

        (,,,,,, EscrowMarketplace.ItemStatus status,,) = marketplace.getItem(itemId);
        assertEq(uint256(status), uint256(EscrowMarketplace.ItemStatus.Refunded));
    }

    function testResolveDisputeInFavorOfSeller() public {
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        marketplace.purchaseItem{value: 1 ether}(itemId);

        vm.prank(buyer);
        marketplace.requestRefund(itemId);

        uint256 initialOwnerBalance = owner.balance;
        uint256 initialSellerBalance = seller.balance;

        uint256 feeAmount = (1 ether * defaultFee) / 10000; // 0.025 ether
        uint256 sellerAmount = 1 ether - feeAmount; // 0.975 ether

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit DisputeResolved(itemId, seller);

        marketplace.resolveDispute(itemId, false);

        assertEq(owner.balance, initialOwnerBalance + feeAmount);
        assertEq(seller.balance, initialSellerBalance + sellerAmount);

        (,,,,,, EscrowMarketplace.ItemStatus status,, uint256 completedAt) = marketplace.getItem(itemId);
        assertEq(uint256(status), uint256(EscrowMarketplace.ItemStatus.Completed));
        assertGt(completedAt, 0);
    }

    function testUpdateFee() public {
        uint256 newFee = 500; // 5%

        vm.prank(owner);
        marketplace.updateFee(newFee);

        assertEq(marketplace.feePercentage(), newFee);
    }

    function test_RevertWhen_ZeroPriceItem() public {
        vm.prank(seller);
        vm.expectRevert("Price must be greater than zero");
        marketplace.listItem("Test Item", "Test Description", 0);
    }

    function test_RevertWhen_PurchaseNonExistentItem() public {
        vm.prank(buyer);
        vm.deal(buyer, 1 ether);
        vm.expectRevert("Item does not exist");
        marketplace.purchaseItem{value: 1 ether}(999);
    }

    function test_RevertWhen_PurchaseOwnItem() public {
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);

        vm.deal(seller, 1 ether);
        vm.prank(seller);
        vm.expectRevert("Seller cannot buy their own item");
        marketplace.purchaseItem{value: 1 ether}(itemId);
    }

    function test_RevertWhen_InsufficientFunds() public {
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);

        vm.deal(buyer, 0.5 ether);
        vm.prank(buyer);
        vm.expectRevert("Insufficient funds sent");
        marketplace.purchaseItem{value: 0.5 ether}(itemId);
    }

    function test_RevertWhen_NonBuyerConfirmDelivery() public {
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        marketplace.purchaseItem{value: 1 ether}(itemId);

        vm.prank(address(4));
        vm.expectRevert("Only buyer can call this function");
        marketplace.confirmDelivery(itemId);
    }

    function test_RevertWhen_ExcessiveFee() public {
        uint256 excessiveFee = 1100; // 11%

        vm.prank(owner);
        vm.expectRevert("Fee cannot exceed 10%");
        marketplace.updateFee(excessiveFee);
    }

    function test_RevertWhen_NonOwnerUpdateFee() public {
        vm.prank(seller);
        vm.expectRevert("Only owner can call this function");
        marketplace.updateFee(300);
    }

    function test_RevertWhen_SellerResolveDispute() public {
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        marketplace.purchaseItem{value: 1 ether}(itemId);

        vm.prank(buyer);
        marketplace.requestRefund(itemId);

        vm.prank(seller);
        vm.expectRevert("Only owner can call this function");
        marketplace.resolveDispute(itemId, true);
    }
}
