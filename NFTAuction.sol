// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/**
 * @title Advanced NFT Auction System
 * @dev Supports both English (ascending price) and Dutch (descending price) auctions
 * @notice This contract implements a secure, gas-efficient NFT auction system with modern features
 */
contract NFTAuction is ReentrancyGuard, Context {
    using Address for address payable;
    using Counters for Counters.Counter;

    enum AuctionType { ENGLISH, DUTCH }
    enum AuctionStatus { NOT_STARTED, ACTIVE, ENDED, CANCELLED }

    struct Auction {
        uint256 id;
        address seller;
        address nftContract;
        uint256 tokenId;
        uint256 startPrice;
        uint256 endPrice;
        uint256 startTime;
        uint256 endTime;
        AuctionType auctionType;
        AuctionStatus status;
        address highestBidder;
        uint256 highestBid;
        uint256 minBidIncrement;
        uint256 priceDropInterval;
    }

    Counters.Counter private _auctionIdCounter;
    mapping(uint256 => Auction) private _auctions;
    mapping(uint256 => mapping(address => uint256)) private _bidderBalances;

    uint256 public constant MIN_AUCTION_DURATION = 1 hours;
    uint256 public constant MAX_AUCTION_DURATION = 30 days;

    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed nftContract,
        uint256 tokenId,
        AuctionType auctionType,
        uint256 startPrice,
        uint256 endPrice,
        uint256 startTime,
        uint256 endTime
    );

    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount,
        uint256 timestamp
    );

    event AuctionExtended(
        uint256 indexed auctionId,
        uint256 newEndTime
    );

    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed winner,
        uint256 winningBid
    );

    event AuctionCancelled(uint256 indexed auctionId);
    event Withdrawal(address indexed account, uint256 amount);

    modifier onlySeller(uint256 auctionId) {
        require(_auctions[auctionId].seller == _msgSender(), "Caller is not the seller");
        _;
    }

    modifier auctionExists(uint256 auctionId) {
        require(_auctions[auctionId].id != 0, "Auction does not exist");
        _;
    }

    modifier isActive(uint256 auctionId) {
        require(_auctions[auctionId].status == AuctionStatus.ACTIVE, "Auction is not active");
        _;
    }

    /**
     * @dev Creates a new auction
     * @param nftContract Address of the NFT contract
     * @param tokenId ID of the NFT token
     * @param startPrice Starting price of the auction (in wei)
     * @param endPrice Ending price of the auction (in wei)
     * @param startTime When the auction should start
     * @param duration Duration of the auction in seconds
     * @param auctionType Type of auction (ENGLISH or DUTCH)
     * @param minBidIncrement Minimum bid increment for English auctions
     * @param priceDropInterval Time interval for price drops in Dutch auctions
     */
    function createAuction(
        address nftContract,
        uint256 tokenId,
        uint256 startPrice,
        uint256 endPrice,
        uint256 startTime,
        uint256 duration,
        AuctionType auctionType,
        uint256 minBidIncrement,
        uint256 priceDropInterval
    ) external {
        require(startPrice > 0, "Start price must be > 0");
        require(duration >= MIN_AUCTION_DURATION && duration <= MAX_AUCTION_DURATION, "Invalid duration");
        require(startTime >= block.timestamp, "Start time must be in the future");
        
        if (auctionType == AuctionType.ENGLISH) {
            require(endPrice > startPrice, "English auction: end price must be > start price");
            require(minBidIncrement > 0, "English auction: min bid increment must be > 0");
        } else {
            require(endPrice < startPrice, "Dutch auction: end price must be < start price");
            require(priceDropInterval > 0, "Dutch auction: price drop interval must be > 0");
        }

        // Transfer NFT to this contract
        IERC721(nftContract).transferFrom(_msgSender(), address(this), tokenId);

        uint256 auctionId = _auctionIdCounter.current();
        _auctionIdCounter.increment();

        _auctions[auctionId] = Auction({
            id: auctionId,
            seller: _msgSender(),
            nftContract: nftContract,
            tokenId: tokenId,
            startPrice: startPrice,
            endPrice: endPrice,
            startTime: startTime,
            endTime: startTime + duration,
            auctionType: auctionType,
            status: AuctionStatus.NOT_STARTED,
            highestBidder: address(0),
            highestBid: 0,
            minBidIncrement: minBidIncrement,
            priceDropInterval: priceDropInterval
        });

        emit AuctionCreated(
            auctionId,
            _msgSender(),
            nftContract,
            tokenId,
            auctionType,
            startPrice,
            endPrice,
            startTime,
            startTime + duration
        );
    }

    /**
     * @dev Starts an auction that was created but hasn't started yet
     * @param auctionId ID of the auction to start
     */
    function startAuction(uint256 auctionId) external onlySeller(auctionId) auctionExists(auctionId) {
        Auction storage auction = _auctions[auctionId];
        require(auction.status == AuctionStatus.NOT_STARTED, "Auction already started");
        require(block.timestamp >= auction.startTime, "Auction start time not reached");

        auction.status = AuctionStatus.ACTIVE;
    }

    /**
     * @dev Places a bid on an English auction
     * @param auctionId ID of the auction to bid on
     */
    function placeBid(uint256 auctionId) external payable nonReentrant auctionExists(auctionId) isActive(auctionId) {
        Auction storage auction = _auctions[auctionId];
        require(auction.auctionType == AuctionType.ENGLISH, "Only English auctions accept bids");
        require(block.timestamp >= auction.startTime, "Auction not started yet");
        require(block.timestamp <= auction.endTime, "Auction already ended");

        uint256 currentPrice = getCurrentPrice(auctionId);
        uint256 minBid = auction.highestBid == 0 
            ? currentPrice 
            : auction.highestBid + auction.minBidIncrement;

        require(msg.value >= minBid, "Bid too low");

        // Refund previous highest bidder
        if (auction.highestBidder != address(0)) {
            _bidderBalances[auctionId][auction.highestBidder] += auction.highestBid;
        }

        auction.highestBidder = _msgSender();
        auction.highestBid = msg.value;

        // Extend auction if bid is placed near the end (15 minute buffer)
        if (auction.endTime - block.timestamp < 15 minutes) {
            auction.endTime = block.timestamp + 15 minutes;
            emit AuctionExtended(auctionId, auction.endTime);
        }

        emit BidPlaced(auctionId, _msgSender(), msg.value, block.timestamp);
    }

    /**
     * @dev Buys an item in a Dutch auction
     * @param auctionId ID of the auction to buy from
     */
    function buyNow(uint256 auctionId) external payable nonReentrant auctionExists(auctionId) isActive(auctionId) {
        Auction storage auction = _auctions[auctionId];
        require(auction.auctionType == AuctionType.DUTCH, "Only Dutch auctions support buy now");
        require(block.timestamp >= auction.startTime, "Auction not started yet");
        require(block.timestamp <= auction.endTime, "Auction already ended");

        uint256 currentPrice = getCurrentPrice(auctionId);
        require(msg.value >= currentPrice, "Insufficient funds");

        auction.highestBidder = _msgSender();
        auction.highestBid = currentPrice;
        auction.status = AuctionStatus.ENDED;

        // Transfer NFT to buyer
        IERC721(auction.nftContract).transferFrom(address(this), _msgSender(), auction.tokenId);

        // Transfer funds to seller (minus any excess)
        uint256 excess = msg.value - currentPrice;
        if (excess > 0) {
            payable(_msgSender()).sendValue(excess);
        }
        payable(auction.seller).sendValue(currentPrice);

        emit AuctionSettled(auctionId, _msgSender(), currentPrice);
    }

    /**
     * @dev Settles an English auction after it ends
     * @param auctionId ID of the auction to settle
     */
    function settleAuction(uint256 auctionId) external nonReentrant auctionExists(auctionId) {
        Auction storage auction = _auctions[auctionId];
        require(auction.status == AuctionStatus.ACTIVE, "Auction not active");
        require(block.timestamp > auction.endTime, "Auction not ended yet");
        require(auction.auctionType == AuctionType.ENGLISH, "Only English auctions need settling");

        auction.status = AuctionStatus.ENDED;

        if (auction.highestBidder != address(0)) {
            // Transfer NFT to winner
            IERC721(auction.nftContract).transferFrom(address(this), auction.highestBidder, auction.tokenId);
            
            // Transfer funds to seller
            payable(auction.seller).sendValue(auction.highestBid);

            emit AuctionSettled(auctionId, auction.highestBidder, auction.highestBid);
        } else {
            // No bids - return NFT to seller
            IERC721(auction.nftContract).transferFrom(address(this), auction.seller, auction.tokenId);
            emit AuctionCancelled(auctionId);
        }
    }

    /**
     * @dev Cancels an active auction
     * @param auctionId ID of the auction to cancel
     */
    function cancelAuction(uint256 auctionId) external nonReentrant onlySeller(auctionId) auctionExists(auctionId) {
        Auction storage auction = _auctions[auctionId];
        require(auction.status == AuctionStatus.ACTIVE || auction.status == AuctionStatus.NOT_STARTED, "Cannot cancel");
        require(auction.highestBidder == address(0), "Cannot cancel with existing bids");

        auction.status = AuctionStatus.CANCELLED;

        // Return NFT to seller
        IERC721(auction.nftContract).transferFrom(address(this), auction.seller, auction.tokenId);

        emit AuctionCancelled(auctionId);
    }

    /**
     * @dev Allows bidders to withdraw their outbid funds
     * @param auctionId ID of the auction to withdraw from
     */
    function withdrawBid(uint256 auctionId) external nonReentrant auctionExists(auctionId) {
        uint256 amount = _bidderBalances[auctionId][_msgSender()];
        require(amount > 0, "No funds to withdraw");

        _bidderBalances[auctionId][_msgSender()] = 0;
        payable(_msgSender()).sendValue(amount);

        emit Withdrawal(_msgSender(), amount);
    }

    /**
     * @dev Returns the current price of a Dutch auction
     * @param auctionId ID of the auction to check
     * @return Current price in wei
     */
    function getCurrentPrice(uint256 auctionId) public view auctionExists(auctionId) returns (uint256) {
        Auction storage auction = _auctions[auctionId];
        
        if (block.timestamp < auction.startTime) {
            return auction.startPrice;
        }
        
        if (block.timestamp >= auction.endTime || auction.status != AuctionStatus.ACTIVE) {
            return auction.endPrice;
        }

        if (auction.auctionType == AuctionType.ENGLISH) {
            return auction.highestBid > 0 ? auction.highestBid + auction.minBidIncrement : auction.startPrice;
        } else {
            uint256 elapsed = block.timestamp - auction.startTime;
            uint256 drops = elapsed / auction.priceDropInterval;
            uint256 totalDrops = (auction.endTime - auction.startTime) / auction.priceDropInterval;
            
            if (drops >= totalDrops) {
                return auction.endPrice;
            }
            
            uint256 priceRange = auction.startPrice - auction.endPrice;
            uint256 priceDropPerInterval = priceRange / totalDrops;
            
            return auction.startPrice - (drops * priceDropPerInterval);
        }
    }

    /**
     * @dev Returns auction details
     * @param auctionId ID of the auction to get
     */
    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        return _auctions[auctionId];
    }

    /**
     * @dev Returns a bidder's withdrawable balance for a specific auction
     * @param auctionId ID of the auction
     * @param bidder Address of the bidder
     */
    function getBidderBalance(uint256 auctionId, address bidder) external view returns (uint256) {
        return _bidderBalances[auctionId][bidder];
    }
}
