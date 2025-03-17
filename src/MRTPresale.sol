// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IMRTCollection {
    function mintInternal(address to, string memory tokenURI) external returns (uint256);
}

/**
 * @title MRTPresale
 * @dev Manages presale for the MRT NFT Collection
 */
contract MRTPresale is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    
    // NFT Collection contract
    IMRTCollection public nftCollection;
    
    // MRT token
    IERC20 public mrtToken;
    
    // Presale supply
    uint256 public constant PRESALE_SUPPLY = 1000;
    
    // Pricing structure
    uint256 public basePrice = 0.05 ether;
    uint256 public presalePrice = 0.03 ether;
    uint256 public increaseRate = 0.001 ether; // Price increases with every 1000 NFTs minted
    
    // Sale statuses
    enum SaleStatus { CLOSED, PRESALE, PUBLIC }
    SaleStatus public saleStatus = SaleStatus.CLOSED;
    
    // Whitelist management
    mapping(address => bool) public isWhitelisted;
    mapping(address => uint256) public whitelistMintAllowance;
    
    // Tracking
    uint256 public totalMinted = 0;
    uint256 public totalPresaleMinted = 0;
    
    // Treasury wallet
    address public treasuryWallet;
    
    // Events
    event SaleStatusChanged(SaleStatus newStatus);
    event WhitelistAdded(address[] addresses, uint256 mintAllowance);
    event WhitelistRemoved(address[] addresses);
    event TokenMinted(address indexed buyer, uint256 tokenId, uint256 price);
    event PriceUpdated(uint256 basePrice, uint256 presalePrice, uint256 increaseRate);
    
    /**
     * @dev Constructor
     * @param nftCollectionAddress The address of the NFT collection contract
     * @param mrtTokenAddress The address of the MRT token contract
     * @param treasury The treasury wallet address
     */
    constructor(
        address nftCollectionAddress,
        address mrtTokenAddress,
        address treasury
    ) Ownable(msg.sender) {
        nftCollection = IMRTCollection(nftCollectionAddress);
        mrtToken = IERC20(mrtTokenAddress);
        treasuryWallet = treasury;
    }
    
    /**
     * @dev Update sale status
     * @param newStatus The new sale status (0: CLOSED, 1: PRESALE, 2: PUBLIC)
     */
    function setSaleStatus(SaleStatus newStatus) external onlyOwner {
        saleStatus = newStatus;
        emit SaleStatusChanged(newStatus);
    }
    
    /**
     * @dev Update pricing structure
     * @param _basePrice New base price
     * @param _presalePrice New presale price
     * @param _increaseRate New increase rate
     */
    function updatePricing(
        uint256 _basePrice,
        uint256 _presalePrice,
        uint256 _increaseRate
    ) external onlyOwner {
        basePrice = _basePrice;
        presalePrice = _presalePrice;
        increaseRate = _increaseRate;
        emit PriceUpdated(_basePrice, _presalePrice, _increaseRate);
    }
    
    /**
     * @dev Set treasury wallet
     * @param _treasuryWallet New treasury wallet address
     */
    function setTreasuryWallet(address _treasuryWallet) external onlyOwner {
        treasuryWallet = _treasuryWallet;
    }
    
    /**
     * @dev Add addresses to the whitelist for presale
     * @param addresses The addresses to whitelist
     * @param mintAllowance The number of NFTs each address can mint during presale
     */
    function addToWhitelist(address[] calldata addresses, uint256 mintAllowance) external onlyOwner {
        for (uint256 i = 0; i < addresses.length; i++) {
            isWhitelisted[addresses[i]] = true;
            whitelistMintAllowance[addresses[i]] = mintAllowance;
        }
        emit WhitelistAdded(addresses, mintAllowance);
    }
    
    /**
     * @dev Remove addresses from the whitelist
     * @param addresses The addresses to remove from whitelist
     */
    function removeFromWhitelist(address[] calldata addresses) external onlyOwner {
        for (uint256 i = 0; i < addresses.length; i++) {
            isWhitelisted[addresses[i]] = false;
        }
        emit WhitelistRemoved(addresses);
    }
    
    /**
     * @dev Calculate the current price to mint an NFT
     */
    function getCurrentPrice() public view returns (uint256) {
        if (saleStatus == SaleStatus.PRESALE) {
            return presalePrice;
        }
        
        uint256 priceIncrease = (totalMinted / 1000) * increaseRate;
        return basePrice + priceIncrease;
    }
    
    /**
     * @dev Mint a new NFT during presale
     * @param tokenURI The URI for the token metadata
     */
    function presaleMint(string memory tokenURI) external payable nonReentrant {
        require(saleStatus == SaleStatus.PRESALE, "Presale is not active");
        require(isWhitelisted[msg.sender], "Not whitelisted");
        require(whitelistMintAllowance[msg.sender] > 0, "Presale mint allowance exceeded");
        require(totalPresaleMinted < PRESALE_SUPPLY, "Presale supply exceeded");
        require(msg.value >= presalePrice, "Insufficient funds");
        
        whitelistMintAllowance[msg.sender]--;
        totalPresaleMinted++;
        totalMinted++;
        
        uint256 tokenId = nftCollection.mintInternal(msg.sender, tokenURI);
        
        // Send funds to treasury
        (bool success, ) = treasuryWallet.call{value: msg.value}("");
        require(success, "Failed to send funds to treasury");
        
        emit TokenMinted(msg.sender, tokenId, msg.value);
    }
    
    /**
     * @dev Mint a new NFT during public sale
     * @param tokenURI The URI for the token metadata
     */
    function publicMint(string memory tokenURI) external payable nonReentrant {
        require(saleStatus == SaleStatus.PUBLIC, "Public sale is not active");
        require(msg.value >= getCurrentPrice(), "Insufficient funds");
        
        totalMinted++;
        
        uint256 tokenId = nftCollection.mintInternal(msg.sender, tokenURI);
        
        // Send funds to treasury
        (bool success, ) = treasuryWallet.call{value: msg.value}("");
        require(success, "Failed to send funds to treasury");
        
        emit TokenMinted(msg.sender, tokenId, msg.value);
    }
    
    /**
     * @dev Mint an NFT with MRT tokens
     * @param tokenURI The URI for the token metadata
     */
    function mintWithMRT(string memory tokenURI) external nonReentrant {
        require(saleStatus == SaleStatus.PUBLIC, "Public sale is not active");
        
        uint256 currentPrice = getCurrentPrice();
        uint256 mrtRequired = currentPrice * 100; // Example conversion rate: 1 ETH = 100 MRT
        require(mrtToken.balanceOf(msg.sender) >= mrtRequired, "Insufficient MRT tokens");
        
        // Transfer MRT tokens to treasury
        require(mrtToken.transferFrom(msg.sender, treasuryWallet, mrtRequired), "MRT transfer failed");
        
        totalMinted++;
        
        uint256 tokenId = nftCollection.mintInternal(msg.sender, tokenURI);
        
        emit TokenMinted(msg.sender, tokenId, currentPrice);
    }
    
    /**
     * @dev Withdraw funds in case of emergency
     */
    function withdrawFunds() external onlyOwner {
        (bool success, ) = treasuryWallet.call{value: address(this).balance}("");
        require(success, "Failed to withdraw funds");
    }
    
    /**
     * @dev Receive function to accept ETH payments
     */
    receive() external payable {}
}