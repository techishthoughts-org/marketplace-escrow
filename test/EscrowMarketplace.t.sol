// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/EscrowMarketplace.sol";

contract EscrowMarketplaceTest is Test {
    EscrowMarketplace marketplace;
    address owner = address(1);
    address seller = address(2);
    address buyer = address(3);
    uint256 defaultFee = 250; // 2.5%
    
    // Event signatures
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
        assertEq(uint(status), uint(EscrowMarketplace.ItemStatus.Listed));
        assertEq(completedAt, 0);
        assertGt(createdAt, 0);
    }
    
    function testPurchaseItem() public {
        // First list an item
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);
        
        // Then purchase it
        vm.prank(buyer);
        vm.expectEmit(true, true, false, true);
        emit ItemPurchased(itemId, buyer, 1 ether);
        
        vm.deal(buyer, 2 ether);
        marketplace.purchaseItem{value: 1 ether}(itemId);
        
        // Check item state after purchase
        (,,,, address itemSeller, address itemBuyer, EscrowMarketplace.ItemStatus status,,) = marketplace.getItem(itemId);
        
        assertEq(itemSeller, seller);
        assertEq(itemBuyer, buyer);
        assertEq(uint(status), uint(EscrowMarketplace.ItemStatus.InEscrow));
    }
    
    function testPurchaseItemWithExcessPayment() public {
        // List an item
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);
        
        // Purchase with excess payment
        vm.deal(buyer, 2 ether);
        uint256 initialBalance = buyer.balance;
        
        vm.prank(buyer);
        marketplace.purchaseItem{value: 1.5 ether}(itemId);
        
        // Verify excess payment was refunded
        assertEq(buyer.balance, initialBalance - 1 ether);
        
        // Check item state
        (,,,, address itemSeller, address itemBuyer, EscrowMarketplace.ItemStatus status,,) = marketplace.getItem(itemId);
        assertEq(itemBuyer, buyer);
        assertEq(uint(status), uint(EscrowMarketplace.ItemStatus.InEscrow));
    }
    
    function testConfirmDelivery() public {
        // Setup: List and purchase an item
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);
        
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        marketplace.purchaseItem{value: 1 ether}(itemId);
        
        // Get balances before confirmation
        uint256 initialOwnerBalance = owner.balance;
        uint256 initialSellerBalance = seller.balance;
        
        // Calculate expected payouts
        uint256 feeAmount = (1 ether * defaultFee) / 10000; // 0.025 ether
        uint256 sellerAmount = 1 ether - feeAmount; // 0.975 ether
        
        // Confirm delivery
        vm.prank(buyer);
        vm.expectEmit(true, false, false, false);
        emit ItemDeliveryConfirmed(itemId);
        
        marketplace.confirmDelivery(itemId);
        
        // Check balances after confirmation
        assertEq(owner.balance, initialOwnerBalance + feeAmount);
        assertEq(seller.balance, initialSellerBalance + sellerAmount);
        // Check item status
        (,,,,,, EscrowMarketplace.ItemStatus status,, uint256 completedAt) = marketplace.getItem(itemId);
        assertEq(uint(status), uint(EscrowMarketplace.ItemStatus.Completed));
        assertGt(completedAt, 0);
    }
    
    function testRequestRefund() public {
        // Setup: List and purchase an item
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);
        
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        marketplace.purchaseItem{value: 1 ether}(itemId);
        
        // Request refund
        vm.prank(buyer);
        vm.expectEmit(true, false, false, true);
        emit ItemDisputed(itemId, buyer);
        
        marketplace.requestRefund(itemId);
        
        // Check item status
        (,,,,,, EscrowMarketplace.ItemStatus status,,) = marketplace.getItem(itemId);
        assertEq(uint(status), uint(EscrowMarketplace.ItemStatus.Disputed));
    }
    
    function testAgreeToRefund() public {
        // Setup: List and purchase an item
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);
        
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        marketplace.purchaseItem{value: 1 ether}(itemId);
        
        // Request refund
        vm.prank(buyer);
        marketplace.requestRefund(itemId);
        
        // Get buyer balance before refund
        uint256 initialBuyerBalance = buyer.balance;
        
        // Seller agrees to refund
        vm.prank(seller);
        vm.expectEmit(true, false, false, false);
        emit ItemRefunded(itemId);
        
        marketplace.agreeToRefund(itemId);
        
        // Check buyer received refund
        assertEq(buyer.balance, initialBuyerBalance + 1 ether);
        
        // Check item status
        (,,,,,, EscrowMarketplace.ItemStatus status,,) = marketplace.getItem(itemId);
        assertEq(uint(status), uint(EscrowMarketplace.ItemStatus.Refunded));
    }
    
    function testResolveDisputeRefundToBuyer() public {
        // Setup: List and purchase an item
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);
        
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        marketplace.purchaseItem{value: 1 ether}(itemId);
        
        // Request refund
        vm.prank(buyer);
        marketplace.requestRefund(itemId);
        
        // Get buyer balance before resolution
        uint256 initialBuyerBalance = buyer.balance;
        
        // Owner resolves dispute in favor of buyer
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit DisputeResolved(itemId, buyer);
        
        marketplace.resolveDispute(itemId, true);
        
        // Check buyer received refund
        assertEq(buyer.balance, initialBuyerBalance + 1 ether);
        
        // Check item status
        (,,,,,, EscrowMarketplace.ItemStatus status,,) = marketplace.getItem(itemId);
        assertEq(uint(status), uint(EscrowMarketplace.ItemStatus.Refunded));
    }
    
    function testResolveDisputeInFavorOfSeller() public {
        // Setup: List and purchase an item
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);
        
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        marketplace.purchaseItem{value: 1 ether}(itemId);
        
        // Request refund
        vm.prank(buyer);
        marketplace.requestRefund(itemId);
        
        // Get balances before resolution
        uint256 initialOwnerBalance = owner.balance;
        uint256 initialSellerBalance = seller.balance;
        
        // Calculate expected payouts
        uint256 feeAmount = (1 ether * defaultFee) / 10000; // 0.025 ether
        uint256 sellerAmount = 1 ether - feeAmount; // 0.975 ether
        
        // Owner resolves dispute in favor of seller
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit DisputeResolved(itemId, seller);
        
        marketplace.resolveDispute(itemId, false);
        
        // Check balances after resolution
        assertEq(owner.balance, initialOwnerBalance + feeAmount);
        assertEq(seller.balance, initialSellerBalance + sellerAmount);
        
        // Check item status
        (,,,,,, EscrowMarketplace.ItemStatus status,, uint256 completedAt) = marketplace.getItem(itemId);
        assertEq(uint(status), uint(EscrowMarketplace.ItemStatus.Completed));
        assertGt(completedAt, 0);
    }
    
    function testUpdateFee() public {
        uint256 newFee = 500; // 5%
        
        vm.prank(owner);
        marketplace.updateFee(newFee);
        
        assertEq(marketplace.feePercentage(), newFee);
    }
    
    // Revert Tests - Updated from testFail* pattern
    
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
        // List an item
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);
        
        // Try to purchase own item
        vm.deal(seller, 1 ether);
        vm.prank(seller);
        vm.expectRevert("Seller cannot buy their own item");
        marketplace.purchaseItem{value: 1 ether}(itemId);
    }
    
    function test_RevertWhen_InsufficientFunds() public {
        // List an item
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);
        
        // Try to purchase with insufficient funds
        vm.deal(buyer, 0.5 ether);
        vm.prank(buyer);
        vm.expectRevert("Insufficient funds sent");
        marketplace.purchaseItem{value: 0.5 ether}(itemId);
    }
    
    function test_RevertWhen_NonBuyerConfirmDelivery() public {
        // Setup: List and purchase an item
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);
        
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        marketplace.purchaseItem{value: 1 ether}(itemId);
        
        // Try to confirm delivery as non-buyer
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
        // Setup: List and purchase an item
        vm.prank(seller);
        uint256 itemId = marketplace.listItem("Test Item", "Test Description", 1 ether);
        
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        marketplace.purchaseItem{value: 1 ether}(itemId);
        
        // Request refund
        vm.prank(buyer);
        marketplace.requestRefund(itemId);
        
        // Try to resolve dispute as seller
        vm.prank(seller);
        vm.expectRevert("Only owner can call this function");
        marketplace.resolveDispute(itemId, true);
    }
}