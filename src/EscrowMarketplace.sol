// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract EscrowMarketplace {
    address public owner;
    uint256 public feePercentage;
    uint256 public nextItemId;

    struct Item {
        uint256 id;
        string name;
        string description;
        uint256 price;
        address payable seller;
        address payable buyer;
        ItemStatus status;
        uint256 createdAt;
        uint256 completedAt;
    }

    enum ItemStatus {
        Listed,
        InEscrow,
        Completed,
        Cancelled,
        Disputed,
        Refunded
    }

    mapping(uint256 => Item) public items;

    event ItemListed(uint256 indexed itemId, address indexed seller, uint256 price);
    event ItemPurchased(uint256 indexed itemId, address indexed buyer, uint256 amount);
    event ItemDeliveryConfirmed(uint256 indexed itemId);
    event ItemRefunded(uint256 indexed itemId);
    event ItemDisputed(uint256 indexed itemId, address disputeInitiator);
    event DisputeResolved(uint256 indexed itemId, address winner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    modifier onlySeller(uint256 _itemId) {
        require(msg.sender == items[_itemId].seller, "Only seller can call this function");
        _;
    }

    modifier onlyBuyer(uint256 _itemId) {
        require(msg.sender == items[_itemId].buyer, "Only buyer can call this function");
        _;
    }

    modifier itemExists(uint256 _itemId) {
        require(_itemId < nextItemId, "Item does not exist");
        _;
    }

    constructor(uint256 _feePercentage) {
        owner = msg.sender;
        feePercentage = _feePercentage;
        nextItemId = 1;
    }

    function listItem(string memory _name, string memory _description, uint256 _price) external returns (uint256) {
        require(_price > 0, "Price must be greater than zero");

        uint256 itemId = nextItemId;
        items[itemId] = Item({
            id: itemId,
            name: _name,
            description: _description,
            price: _price,
            seller: payable(msg.sender),
            buyer: payable(address(0)),
            status: ItemStatus.Listed,
            createdAt: block.timestamp,
            completedAt: 0
        });

        nextItemId++;

        emit ItemListed(itemId, msg.sender, _price);
        return itemId;
    }

    function purchaseItem(uint256 _itemId) external payable itemExists(_itemId) {
        Item storage item = items[_itemId];

        require(item.status == ItemStatus.Listed, "Item is not available for purchase");
        require(msg.sender != item.seller, "Seller cannot buy their own item");
        require(msg.value >= item.price, "Insufficient funds sent");

        item.buyer = payable(msg.sender);
        item.status = ItemStatus.InEscrow;

        if (msg.value > item.price) {
            payable(msg.sender).transfer(msg.value - item.price);
        }

        emit ItemPurchased(_itemId, msg.sender, item.price);
    }

    function confirmDelivery(uint256 _itemId) external onlyBuyer(_itemId) itemExists(_itemId) {
        Item storage item = items[_itemId];

        require(item.status == ItemStatus.InEscrow, "Item is not in escrow");

        uint256 fee = (item.price * feePercentage) / 10000;
        uint256 sellerAmount = item.price - fee;

        item.status = ItemStatus.Completed;
        item.completedAt = block.timestamp;

        payable(owner).transfer(fee);
        item.seller.transfer(sellerAmount);

        emit ItemDeliveryConfirmed(_itemId);
    }

    function requestRefund(uint256 _itemId) external onlyBuyer(_itemId) itemExists(_itemId) {
        Item storage item = items[_itemId];

        require(item.status == ItemStatus.InEscrow, "Item is not in escrow");

        item.status = ItemStatus.Disputed;

        emit ItemDisputed(_itemId, msg.sender);
    }

    function agreeToRefund(uint256 _itemId) external onlySeller(_itemId) itemExists(_itemId) {
        Item storage item = items[_itemId];

        require(
            item.status == ItemStatus.InEscrow || item.status == ItemStatus.Disputed,
            "Item must be in escrow or disputed"
        );

        item.status = ItemStatus.Refunded;

        item.buyer.transfer(item.price);

        emit ItemRefunded(_itemId);
    }

    function resolveDispute(uint256 _itemId, bool _refundToBuyer) external onlyOwner itemExists(_itemId) {
        Item storage item = items[_itemId];

        require(item.status == ItemStatus.Disputed, "Item is not disputed");

        if (_refundToBuyer) {
            item.status = ItemStatus.Refunded;
            item.buyer.transfer(item.price);
            emit DisputeResolved(_itemId, item.buyer);
        } else {
            uint256 fee = (item.price * feePercentage) / 10000;
            uint256 sellerAmount = item.price - fee;

            item.status = ItemStatus.Completed;
            item.completedAt = block.timestamp;

            payable(owner).transfer(fee);
            item.seller.transfer(sellerAmount);

            emit DisputeResolved(_itemId, item.seller);
        }
    }

    function updateFee(uint256 _newFeePercentage) external onlyOwner {
        require(_newFeePercentage <= 1000, "Fee cannot exceed 10%");
        feePercentage = _newFeePercentage;
    }

    function getItem(uint256 _itemId)
        external
        view
        itemExists(_itemId)
        returns (
            uint256 id,
            string memory name,
            string memory description,
            uint256 price,
            address seller,
            address buyer,
            ItemStatus status,
            uint256 createdAt,
            uint256 completedAt
        )
    {
        Item storage item = items[_itemId];
        return (
            item.id,
            item.name,
            item.description,
            item.price,
            item.seller,
            item.buyer,
            item.status,
            item.createdAt,
            item.completedAt
        );
    }
}
