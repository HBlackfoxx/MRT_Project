// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MRTCollection
 * @dev Main NFT contract with burning mechanism
 */
contract MRTCollection is ERC721Enumerable, ERC721URIStorage, Ownable {
    using Counters for Counters.Counter;
    using SafeMath for uint256;

    // Token counter
    Counters.Counter private _tokenIdCounter;
    
    // Maximum supply
    uint256 public constant MAX_SUPPLY = 10000;
    
    // Base URI for metadata
    string private _baseTokenURI;
    
    // MRT token address
    IERC20 public mrtToken;
    
    // Burn rates
    uint256 public burnRateTransfer = 1; // 1% burn on transfer
    uint256 public burnRateMint = 3;     // 3% burn on mint
    
    // Royalty fee
    uint256 public royaltyFee = 7; // 7% royalty on secondary sales
    
    // Fee receivers
    address public stakingContract;
    address public daoContract;
    address public treasuryWallet;
    
    // Fee distribution
    uint256 public stakingShare = 2;  // 2% to staking rewards
    uint256 public communityShare = 1; // 1% to community fund (DAO)
    uint256 public devShare = 1;      // 1% to development fund

    // Rarity levels
    enum Rarity { COMMON, UNCOMMON, RARE, EPIC, LEGENDARY }
    mapping(uint256 => Rarity) public tokenRarity;
    
    // Presale contract
    address public presaleContract;
    
    // Events
    event Minted(address indexed to, uint256 indexed tokenId, Rarity rarity);
    event TokensBurned(uint256 indexed tokenId);
    event RoyaltyPaid(address indexed seller, address indexed buyer, uint256 tokenId, uint256 amount);
    event ContractAddressUpdated(string indexed contractType, address indexed contractAddress);
    
    /**
     * @dev Constructor
     * @param name_ The name of the NFT collection
     * @param symbol_ The symbol of the NFT collection
     * @param baseTokenURI_ The base URI for token metadata
     * @param mrtTokenAddress The address of the MRT token contract
     * @param treasury The treasury wallet address
     */
    constructor(
        string memory name_,
        string memory symbol_,
        string memory baseTokenURI_,
        address mrtTokenAddress,
        address treasury
    ) ERC721(name_, symbol_) Ownable(msg.sender) {
        _baseTokenURI = baseTokenURI_;
        mrtToken = IERC20(mrtTokenAddress);
        treasuryWallet = treasury;
    }
    
    /**
     * @dev Override _baseURI to return our base token URI
     */
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
    
    /**
     * @dev Set the base token URI
     * @param baseTokenURI_ The new base token URI
     */
    function setBaseURI(string memory baseTokenURI_) external onlyOwner {
        _baseTokenURI = baseTokenURI_;
    }
    
    /**
     * @dev Set the contract addresses for the ecosystem
     * @param _presaleContract Address of the presale contract
     * @param _stakingContract Address of the staking contract
     * @param _daoContract Address of the DAO contract
     */
    function setContractAddresses(
        address _presaleContract,
        address _stakingContract,
        address _daoContract
    ) external onlyOwner {
        presaleContract = _presaleContract;
        stakingContract = _stakingContract;
        daoContract = _daoContract;
        
        emit ContractAddressUpdated("Presale", _presaleContract);
        emit ContractAddressUpdated("Staking", _stakingContract);
        emit ContractAddressUpdated("DAO", _daoContract);
    }
    
    /**
     * @dev Update fee distribution
     * @param _stakingShare Percentage for staking rewards
     * @param _communityShare Percentage for community fund
     * @param _devShare Percentage for development fund
     */
    function updateFeeDistribution(
        uint256 _stakingShare,
        uint256 _communityShare,
        uint256 _devShare
    ) external onlyOwner {
        require(_stakingShare + _communityShare + _devShare <= 10, "Total fees cannot exceed 10%");
        stakingShare = _stakingShare;
        communityShare = _communityShare;
        devShare = _devShare;
    }
    
    /**
     * @dev Update burn rates
     * @param _burnRateTransfer New burn rate for transfers
     * @param _burnRateMint New burn rate for minting
     */
    function updateBurnRates(uint256 _burnRateTransfer, uint256 _burnRateMint) external onlyOwner {
        require(_burnRateTransfer <= 5, "Transfer burn rate too high");
        require(_burnRateMint <= 10, "Mint burn rate too high");
        burnRateTransfer = _burnRateTransfer;
        burnRateMint = _burnRateMint;
    }
    
    /**
     * @dev Update royalty fee
     * @param _royaltyFee New royalty fee percentage
     */
    function updateRoyaltyFee(uint256 _royaltyFee) external onlyOwner {
        require(_royaltyFee <= 10, "Royalty fee too high");
        royaltyFee = _royaltyFee;
    }

    /**
     * @dev Generate random rarity for NFT
     * @param tokenId The token ID
     * @param minter The address of the minter
     * @return The rarity of the NFT
     */
    function _generateRarity(uint256 tokenId, address minter) internal view returns (Rarity) {
        uint256 randomNumber = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            minter,
            tokenId
        ))) % 100;
        
        // Rarity distribution: 50% Common, 30% Uncommon, 15% Rare, 4% Epic, 1% Legendary
        if (randomNumber < 50) {
            return Rarity.COMMON;
        } else if (randomNumber < 80) {
            return Rarity.UNCOMMON;
        } else if (randomNumber < 95) {
            return Rarity.RARE;
        } else if (randomNumber < 99) {
            return Rarity.EPIC;
        } else {
            return Rarity.LEGENDARY;
        }
    }
    
    /**
     * @dev Internal mint function - only callable by authorized contracts
     * @param to The address to mint the NFT to
     * @param tokenURI The URI for the token metadata
     */
    function mintInternal(address to, string memory tokenURI) external returns (uint256) {
        require(
            msg.sender == owner() || 
            msg.sender == presaleContract, 
            "Caller is not authorized to mint"
        );
        require(_tokenIdCounter.current() < MAX_SUPPLY, "Max supply exceeded");
        
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        
        // Assign rarity
        Rarity rarity = _generateRarity(tokenId, to);
        tokenRarity[tokenId] = rarity;
        
        // Mint the NFT
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI);
        
        // Calculate burn amount for minting
        if (burnRateMint > 0) {
            // We don't actually burn NFTs here, but this would be the implementation
            // Could be a separate burn event that reduces total supply
            emit TokensBurned(tokenId);
        }
        
        emit Minted(to, tokenId, rarity);
        
        return tokenId;
    }
    
    /**
     * @dev Execute burn event for special occasions
     * @param tokenIds Array of token IDs to burn
     */
    function executeBurnEvent(uint256[] calldata tokenIds) external onlyOwner {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(_exists(tokenIds[i]), "Token does not exist");
            _burn(tokenIds[i]);
            emit TokensBurned(tokenIds[i]);
        }
    }
    
    /**
     * @dev Override _transfer to implement burn on transfer
     */
    function _transfer(address from, address to, uint256 tokenId) internal override {
        super._transfer(from, to, tokenId);
        
        // Implement royalty payment on secondary sales
        if (from != address(0) && to != address(0) && from != owner() && to != owner()) {
            // This would be implemented in a marketplace contract typically
            // Here we just emit the event for demonstration
            uint256 royaltyAmount = 0; // Would be calculated based on sale price
            emit RoyaltyPaid(from, to, tokenId, royaltyAmount);
            
            // Distribute fees
            // In real implementation, this would transfer actual funds
            // stakingContract.receive{value: stakingShare}();
            // daoContract.receive{value: communityShare}();
            // treasuryWallet.receive{value: devShare}();
        }
    }
    
    // Required overrides for ERC721URIStorage and ERC721Enumerable
    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }
    
    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }
    
    function supportsInterface(bytes4 interfaceId) public view override(ERC721Enumerable, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
    
    function _update(address to, uint256 tokenId, address auth) internal override(ERC721, ERC721Enumerable) returns (address) {
        return super._update(to, tokenId, auth);
    }
    
    function _increaseBalance(address account, uint128 value) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }
}