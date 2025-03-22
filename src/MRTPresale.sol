// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface IMRTCollection {
    enum Rarity { COMMON, UNCOMMON, RARE, EPIC, LEGENDARY }
    function mintInternal(address to, bytes memory signature, bytes32 nonce) external returns (uint256);
}

/**
 * @title MRTPresale
 * @dev Manages multiple presales for the MRT NFT Collection with public and private options
 */
contract MRTPresale is Ownable, ReentrancyGuard {
    
    // NFT Collection contract
    IMRTCollection public nftCollection;
    
    // MRT token
    IERC20 public mrtToken;
    
    // Presale struct
    struct PresaleConfig {
        uint256 id;
        uint256 startTime;
        uint256 endTime;
        uint256 maxSupply;
        uint256 basePrice;         // In ETH
        uint256 mrtBasePrice;      // In MRT tokens
        uint256 priceIncreaseRate; // ETH increase per mint
        uint256 mrtPriceIncreaseRate; // MRT increase per mint
        bytes32 merkleRoot;        // For private presales
        bool isPrivate;
        bool isActive;
        uint256 totalMinted;
    }
    
    // Fee distribution addresses
    address public stakingContract;    // 2% - Staking reward
    address public communityContract;  // 2% - Community reward
    address public devWallet;          // 1% - Development & Operations
    address public marketingWallet;    // 1% - Marketing & Community
    address public teamWallet;         // 1% - Founders & Team Growth Fund
    address public daoContract;        // 93% - Treasury
    
    // Presale management
    mapping(uint256 => PresaleConfig) public presales;
    uint256 public presaleCount;
    
    // Used tokens tracking (for private presales)
    mapping(uint256 => mapping(address => uint256)) public presaleMinted;

    // Trusted oracle for randomness verification
    address public trustedOracle;
    
    // Events
    event PresaleCreated(uint256 indexed presaleId, bool isPrivate, uint256 startTime, uint256 endTime);
    event PresaleUpdated(uint256 indexed presaleId, bool isActive);
    event TokenMinted(address indexed buyer, uint256 indexed presaleId, uint256 tokenId, uint256 price, bool usedMRT);
    event FeeDistributionUpdated(address stakingContract, address communityContract, address devWallet, address marketingWallet, address teamWallet, address daoContract);
    event MerkleRootUpdated(uint256 indexed presaleId, bytes32 merkleRoot);
    
    /**
     * @dev Constructor
     * @param nftCollectionAddress The address of the NFT collection contract
     * @param mrtTokenAddress The address of the MRT token contract
     * @param _trustedOracle The trusted oracle address for randomness verification
     * @param _stakingContract Staking contract address (2%)
     * @param _communityContract Community reward contract address (2%)
     * @param _devWallet Development & Operations wallet (1%)
     * @param _marketingWallet Marketing & Community wallet (1%)
     * @param _teamWallet Founders & Team Growth Fund wallet (1%)
     * @param _daoContract DAO contract address/treasury (93%)
     */
    constructor(
        address nftCollectionAddress,
        address mrtTokenAddress,
        address _trustedOracle,
        address _stakingContract,
        address _communityContract,
        address _devWallet,
        address _marketingWallet,
        address _teamWallet,
        address _daoContract
    ) Ownable(msg.sender) {
        nftCollection = IMRTCollection(nftCollectionAddress);
        mrtToken = IERC20(mrtTokenAddress);
        trustedOracle = _trustedOracle;
        
        stakingContract = _stakingContract;
        communityContract = _communityContract;
        devWallet = _devWallet;
        marketingWallet = _marketingWallet;
        teamWallet = _teamWallet;
        daoContract = _daoContract;
    }
    
    /**
     * @dev Update fee distribution addresses
     * @param _stakingContract Staking contract address (2%)
     * @param _communityContract Community reward contract address (2%)
     * @param _devWallet Development & Operations wallet (1%)
     * @param _marketingWallet Marketing & Community wallet (1%)
     * @param _teamWallet Founders & Team Growth Fund wallet (1%)
     * @param _daoContract DAO contract address/treasury (93%)
     */
    function updateFeeDistribution(
        address _stakingContract,
        address _communityContract,
        address _devWallet,
        address _marketingWallet,
        address _teamWallet,
        address _daoContract
    ) external onlyOwner {
        require(_stakingContract != address(0), "Invalid staking contract address");
        require(_communityContract != address(0), "Invalid community contract address");
        require(_devWallet != address(0), "Invalid dev wallet address");
        require(_marketingWallet != address(0), "Invalid marketing wallet address");
        require(_teamWallet != address(0), "Invalid team wallet address");
        require(_daoContract != address(0), "Invalid DAO contract address");
        
        stakingContract = _stakingContract;
        communityContract = _communityContract;
        devWallet = _devWallet;
        marketingWallet = _marketingWallet;
        teamWallet = _teamWallet;
        daoContract = _daoContract;
        
        emit FeeDistributionUpdated(_stakingContract, _communityContract, _devWallet, _marketingWallet, _teamWallet, _daoContract);
    }

    /**
     * @dev Update trusted oracle address
     * @param _trustedOracle New trusted oracle address
     */
    function updateTrustedOracle(address _trustedOracle) external onlyOwner {
        require(_trustedOracle != address(0), "Invalid oracle address");
        trustedOracle = _trustedOracle;
    }
    
    /**
     * @dev Create a new presale
     * @param startTime Presale start timestamp
     * @param endTime Presale end timestamp
     * @param maxSupply Maximum NFTs that can be minted in this presale
     * @param basePrice Base price in ETH (wei)
     * @param mrtBasePrice Base price in MRT tokens
     * @param priceIncreaseRate Rate at which ETH price increases per mint
     * @param mrtPriceIncreaseRate Rate at which MRT price increases per mint
     * @param merkleRoot Merkle root for private presale validation
     * @param isPrivate Whether this presale is private (requires merkle proof)
     * @return presaleId The ID of the created presale
     */
    function createPresale(
        uint256 startTime,
        uint256 endTime,
        uint256 maxSupply,
        uint256 basePrice,
        uint256 mrtBasePrice,
        uint256 priceIncreaseRate,
        uint256 mrtPriceIncreaseRate,
        bytes32 merkleRoot,
        bool isPrivate
    ) external onlyOwner returns (uint256) {
        require(startTime < endTime, "Invalid time range");
        require(startTime > block.timestamp, "Start time must be in the future");
        require(maxSupply > 0, "Max supply must be greater than 0");
        
        // If private, require valid merkle root
        if (isPrivate) {
            require(merkleRoot != bytes32(0), "Private presale requires merkle root");
        }
        
        uint256 presaleId = presaleCount;
        presaleCount++;
        
        presales[presaleId] = PresaleConfig({
            id: presaleId,
            startTime: startTime,
            endTime: endTime,
            maxSupply: maxSupply,
            basePrice: basePrice,
            mrtBasePrice: mrtBasePrice,
            priceIncreaseRate: priceIncreaseRate,
            mrtPriceIncreaseRate: mrtPriceIncreaseRate,
            merkleRoot: merkleRoot,
            isPrivate: isPrivate,
            isActive: true,
            totalMinted: 0
        });
        
        emit PresaleCreated(presaleId, isPrivate, startTime, endTime);
        
        return presaleId;
    }
    
    /**
     * @dev Update merkle root for a private presale
     * @param presaleId ID of the presale
     * @param merkleRoot New merkle root
     */
    function updateMerkleRoot(uint256 presaleId, bytes32 merkleRoot) external onlyOwner {
        require(presaleId < presaleCount, "Presale does not exist");
        require(presales[presaleId].isPrivate, "Not a private presale");
        require(merkleRoot != bytes32(0), "Invalid merkle root");
        
        presales[presaleId].merkleRoot = merkleRoot;
        
        emit MerkleRootUpdated(presaleId, merkleRoot);
    }
    
    /**
     * @dev Update presale status
     * @param presaleId ID of the presale
     * @param isActive New active status
     */
    function updatePresaleStatus(uint256 presaleId, bool isActive) external onlyOwner {
        require(presaleId < presaleCount, "Presale does not exist");
        
        presales[presaleId].isActive = isActive;
        
        emit PresaleUpdated(presaleId, isActive);
    }
    
    /**
     * @dev Calculate current ETH price for a presale
     * @param presaleId ID of the presale
     * @return Current price in ETH (wei)
     */
    function getCurrentPrice(uint256 presaleId) public view returns (uint256) {
        require(presaleId < presaleCount, "Presale does not exist");
        
        PresaleConfig storage presale = presales[presaleId];
        return presale.basePrice + (presale.totalMinted * presale.priceIncreaseRate);
    }
    
    /**
     * @dev Calculate current MRT price for a presale
     * @param presaleId ID of the presale
     * @return Current price in MRT tokens
     */
    function getCurrentMRTPrice(uint256 presaleId) public view returns (uint256) {
        require(presaleId < presaleCount, "Presale does not exist");
        
        PresaleConfig storage presale = presales[presaleId];
        return presale.mrtBasePrice + (presale.totalMinted * presale.mrtPriceIncreaseRate);
    }
    
    /**
     * @dev Check if an address is eligible for a private presale
     * @param presaleId ID of the presale
     * @param account Address to check
     * @param proof Merkle proof
     * @return Whether the address is eligible
     */
    function isEligibleForPrivatePresale(
        uint256 presaleId, 
        address account, 
        bytes32[] calldata proof
    ) public view returns (bool) {
        require(presaleId < presaleCount, "Presale does not exist");
        require(presales[presaleId].isPrivate, "Not a private presale");
        
        bytes32 leaf = keccak256(abi.encodePacked(account));
        return MerkleProof.verify(proof, presales[presaleId].merkleRoot, leaf);
    }
    
    /**
     * @dev Check if a presale is active
     * @param presaleId ID of the presale
     * @return Whether the presale is active
     */
    function isPresaleActive(uint256 presaleId) public view returns (bool) {
        require(presaleId < presaleCount, "Presale does not exist");
        
        PresaleConfig storage presale = presales[presaleId];
        
        return (
            presale.isActive &&
            block.timestamp >= presale.startTime &&
            block.timestamp <= presale.endTime &&
            presale.totalMinted < presale.maxSupply
        );
    }
    
    /**
     * @dev Mint an NFT with ETH
     * @param presaleId ID of the presale
     * @param proof Merkle proof (for private presales)
     * @param signature Oracle signature for rarity verification
     */
    function mintWithETH(
        uint256 presaleId, 
        bytes32[] calldata proof,
        bytes memory signature,
        bytes32 nonce
    ) external payable nonReentrant {
        require(presaleId < presaleCount, "Presale does not exist");
        require(isPresaleActive(presaleId), "Presale is not active");
        
        PresaleConfig storage presale = presales[presaleId];
        
        // Check eligibility for private presale
        if (presale.isPrivate) {
            require(isEligibleForPrivatePresale(presaleId, msg.sender, proof), "Not eligible for private presale");
        }
        
        uint256 price = getCurrentPrice(presaleId);
        require(msg.value == price, "Insufficient ETH sent");
        
        // Increment minted count
        presale.totalMinted++;
        if (presale.isPrivate) {
            presaleMinted[presaleId][msg.sender]++;
        }
        
        // Distribute fees (percentages are fixed)
        uint256 stakingAmount = (msg.value * 2) / 100;  // 2%
        uint256 communityAmount = (msg.value * 2) / 100; // 2%
        uint256 devAmount = (msg.value * 1) / 100;      // 1%
        uint256 marketingAmount = (msg.value * 1) / 100; // 1%
        uint256 teamAmount = (msg.value * 1) / 100;     // 1%
        uint256 daoAmount = msg.value - stakingAmount - communityAmount - devAmount - marketingAmount - teamAmount; // Remaining 93%
        
        // Send funds
        (bool s1,) = stakingContract.call{value: stakingAmount}("");
        (bool s2,) = communityContract.call{value: communityAmount}("");
        (bool s3,) = devWallet.call{value: devAmount}("");
        (bool s4,) = marketingWallet.call{value: marketingAmount}("");
        (bool s5,) = teamWallet.call{value: teamAmount}("");
        (bool s6,) = daoContract.call{value: daoAmount}("");
        
        require(s1 && s2 && s3 && s4 && s5 && s6, "Fee distribution failed");
        
        // Mint the NFT
        uint256 tokenId = nftCollection.mintInternal(msg.sender, signature , nonce);
        
        emit TokenMinted(msg.sender, presaleId, tokenId, price, false);
    }
    
    /**
     * @dev Mint an NFT with MRT tokens
     * @param presaleId ID of the presale
     * @param proof Merkle proof (for private presales)
     * @param signature Oracle signature for rarity verification
     */
    function mintWithMRT(
        uint256 presaleId, 
        bytes32[] calldata proof,
        bytes memory signature,
        bytes32 nonce
    ) external nonReentrant {
        require(presaleId < presaleCount, "Presale does not exist");
        require(isPresaleActive(presaleId), "Presale is not active");
        
        PresaleConfig storage presale = presales[presaleId];
        
        // Check eligibility for private presale
        if (presale.isPrivate) {
            require(isEligibleForPrivatePresale(presaleId, msg.sender, proof), "Not eligible for private presale");
        }
        
        uint256 mrtAmount = getCurrentMRTPrice(presaleId);
        require(mrtToken.balanceOf(msg.sender) >= mrtAmount, "Insufficient MRT balance");
        
        // Increment minted count
        presale.totalMinted++;
        if (presale.isPrivate) {
            presaleMinted[presaleId][msg.sender]++;
        }
        
        // Calculate fee distribution
        uint256 stakingAmount = (mrtAmount * 2) / 100;  // 2%
        uint256 communityAmount = (mrtAmount * 2) / 100; // 2%
        uint256 devAmount = (mrtAmount * 1) / 100;      // 1%
        uint256 marketingAmount = (mrtAmount * 1) / 100; // 1%
        uint256 teamAmount = (mrtAmount * 1) / 100;     // 1%
        uint256 daoAmount = mrtAmount - stakingAmount - communityAmount - devAmount - marketingAmount - teamAmount; // Remaining 93%
        
        // Transfer MRT tokens from sender to fee recipients
        require(mrtToken.transferFrom(msg.sender, stakingContract, stakingAmount), "Staking fee transfer failed");
        require(mrtToken.transferFrom(msg.sender, communityContract, communityAmount), "Community fee transfer failed");
        require(mrtToken.transferFrom(msg.sender, devWallet, devAmount), "Dev fee transfer failed");
        require(mrtToken.transferFrom(msg.sender, marketingWallet, marketingAmount), "Marketing fee transfer failed");
        require(mrtToken.transferFrom(msg.sender, teamWallet, teamAmount), "Team fee transfer failed");
        require(mrtToken.transferFrom(msg.sender, daoContract, daoAmount), "DAO fee transfer failed");
        
        // Mint the NFT
        uint256 tokenId = nftCollection.mintInternal(msg.sender, signature, nonce);
        
        emit TokenMinted(msg.sender, presaleId, tokenId, mrtAmount, true);
    }
    
    /**
     * @dev Get number of NFTs minted by an address in a private presale
     * @param presaleId ID of the presale
     * @param account Address to check
     * @return Number of NFTs minted
     */
    function getPresaleMinted(uint256 presaleId, address account) external view returns (uint256) {
        require(presaleId < presaleCount, "Presale does not exist");
        return presaleMinted[presaleId][account];
    }
    
    /**
     * @dev Update presale configuration (only specific parameters)
     * @param presaleId ID of the presale
     * @param startTime New start time
     * @param endTime New end time
     * @param basePrice New base price in ETH
     * @param mrtBasePrice New base price in MRT
     * @param priceIncreaseRate New price increase rate per mint in ETH
     * @param mrtPriceIncreaseRate New price increase rate per mint in MRT
     */
    function updatePresaleConfig(
        uint256 presaleId,
        uint256 startTime,
        uint256 endTime,
        uint256 basePrice,
        uint256 mrtBasePrice,
        uint256 priceIncreaseRate,
        uint256 mrtPriceIncreaseRate
    ) external onlyOwner {
        require(presaleId < presaleCount, "Presale does not exist");
        require(startTime < endTime, "Invalid time range");
        
        PresaleConfig storage presale = presales[presaleId];
        
        // Don't allow changing start time if presale has already started
        if (block.timestamp >= presale.startTime) {
            require(startTime <= block.timestamp, "Cannot change start time after presale has started");
        }
        
        presale.startTime = startTime;
        presale.endTime = endTime;
        presale.basePrice = basePrice;
        presale.mrtBasePrice = mrtBasePrice;
        presale.priceIncreaseRate = priceIncreaseRate;
        presale.mrtPriceIncreaseRate = mrtPriceIncreaseRate;
        
        emit PresaleUpdated(presaleId, presale.isActive);
    }
    
    /**
     * @dev Emergency pause all presales
     */
    function pauseAllPresales() external onlyOwner {
        for (uint256 i = 0; i < presaleCount; i++) {
            presales[i].isActive = false;
            emit PresaleUpdated(i, false);
        }
    }
    
    /**
     * @dev Emergency withdraw funds
     */
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = daoContract.call{value: balance}("");
            require(success, "Withdrawal failed");
        }
    }
    
    /**
     * @dev Emergency withdraw ERC20 tokens
     * @param tokenAddress Address of the token to withdraw
     */
    function emergencyWithdrawERC20(address tokenAddress) external onlyOwner {
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");
        require(token.transfer(daoContract, balance), "Token transfer failed");
    }
    
    /**
     * @dev Receive function to accept ETH payments
     */
    receive() external payable {}
}