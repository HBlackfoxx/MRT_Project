// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";

/**
 * @title MRTCollection
 * @dev Main NFT contract with burning mechanism and team tax allocation
 * @notice Updated to support batch minting with multiple rarities
 */
contract MRTCollection is ERC721Enumerable, ERC721URIStorage, ERC2981, Ownable {    
    // Simple counter replacement
    uint256 private _currentTokenId;
    
    // Base URI for metadata
    string private _baseTokenURI;
    
    // MRT token address
    IERC20 public mrtToken;

    // Fee receivers & contract addresses
    address public daoContract; // DAO address also serves as treasury
    address public trustedOracle; // For off-chain randomness verification
    
    // Rarity levels
    enum Rarity { COMMON, UNCOMMON, RARE, EPIC, LEGENDARY }
    mapping(uint256 => Rarity) public tokenRarity;
    
    // Mapping to store tokenURI for each rarity level
    mapping(Rarity => string) public rarityToURI;
    
    // TokenURI mapping (predefined)
    mapping(uint256 => string) private _tokenURIs;
    
    // Presale contract
    address public presaleContract;
    
    // Nonce tracking to prevent replay attacks
    mapping(bytes32 => bool) public usedNonces;
    
    // Events
    event Minted(address indexed to, uint256 indexed tokenId, Rarity rarity);
    event BatchMinted(address indexed to, uint256[] tokenIds, uint256 quantity);
    event TokensBurned(uint256 indexed tokenId);
    event ContractAddressUpdated(string indexed contractType, address indexed contractAddress);
    event RaritySet(uint256 indexed tokenId, Rarity rarity);
    event RarityURISet(Rarity indexed rarity, string tokenURI);
    event NonceUsed(bytes32 nonceHash);
    
    /**
     * @dev Constructor
     * @param baseTokenURI_ The base URI for token metadata
     * @param mrtTokenAddress The address of the MRT token contract
     * @param _trustedOracle The trusted oracle address for randomness verification
     * @param _daoContract The DAO contract address (also serves as treasury)
     * @param _royaltyPercentage The royalty percentage (between 5-10%)
     */
    constructor(
        string memory baseTokenURI_,
        address mrtTokenAddress,
        address _trustedOracle,
        address _daoContract,
        uint96 _royaltyPercentage
    ) ERC721("Meana Raptor Genesis", "MRNFT") Ownable(msg.sender) {
        _baseTokenURI = baseTokenURI_;
        mrtToken = IERC20(mrtTokenAddress);
        trustedOracle = _trustedOracle;
        
        require(_daoContract != address(0), "DAO address cannot be zero");
        require(_royaltyPercentage >= 500 && _royaltyPercentage <= 1000, "Royalty must be between 5-10%");
        
        daoContract = _daoContract;
        _setDefaultRoyalty(_daoContract, _royaltyPercentage);
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
     * @param _daoContract Address of the DAO contract (also serves as treasury)
     */
    function setContractAddresses(
        address _presaleContract,
        address _daoContract
    ) external onlyOwner {
        presaleContract = _presaleContract;        
        require(_daoContract != address(0), "DAO address cannot be zero");
        daoContract = _daoContract;
        
        // Update royalty receiver to the new DAO address
        (, uint256 royaltyAmount) = royaltyInfo(0, 10000);
        _setDefaultRoyalty(_daoContract, uint96(royaltyAmount));
        
        emit ContractAddressUpdated("Presale", _presaleContract);
        emit ContractAddressUpdated("DAO", _daoContract);
    }
    
    /**
     * @dev Update trusted oracle address
     * @param _trustedOracle New trusted oracle address
     */
    function updateTrustedOracle(address _trustedOracle) external onlyOwner {
        trustedOracle = _trustedOracle;
    }

    /**
     * @dev Set tokenURI for a specific rarity level
     * @param rarity The rarity level
     * @param _tokenURI The URI for the rarity level
     */
    function setRarityURI(Rarity rarity, string memory _tokenURI) external onlyOwner {
        rarityToURI[rarity] = _tokenURI;
        emit RarityURISet(rarity, _tokenURI);
    }

    /**
     * @dev Set the default royalty for all NFTs
     * @param _royaltyPercentage The royalty percentage (between 5-10%)
     */
    function setDefaultRoyalty(uint96 _royaltyPercentage) external onlyOwner {
        require(_royaltyPercentage >= 500 && _royaltyPercentage <= 1000, "Royalty must be between 5-10%");
        require(daoContract != address(0), "DAO address not set");
        
        // ERC2981 uses basis points (1/100 of a percent)
        // 500 = 5%, 1000 = 10%
        _setDefaultRoyalty(daoContract, _royaltyPercentage);
    }

    /**
     * @dev Batch mint function - only callable by authorized contracts
     * @param to The address to mint the NFTs to
     * @param signature The signature from trusted oracle containing rarities information and nonce
     * @param nonce Unique nonce to prevent replay attacks
     * @param quantity Number of NFTs to mint in this batch
     * @return tokenIds Array of minted token IDs
     */
    function batchMintInternal(
        address to, 
        bytes memory signature, 
        bytes32 nonce,
        uint256 quantity
    ) external returns (uint256[] memory) {
        require(
            msg.sender == owner() || 
            msg.sender == presaleContract, 
            "Caller is not authorized to mint"
        );
        
        // Verify nonce hasn't been used
        bytes32 nonceHash = keccak256(abi.encodePacked(nonce));
        require(!usedNonces[nonceHash], "Nonce already used");
        
        // Mark nonce as used
        usedNonces[nonceHash] = true;
        emit NonceUsed(nonceHash);
        
        // Extract rarities from signature
        (Rarity[] memory rarities, address signer) = verifyAndExtractRarities(to, nonce, quantity, signature);
        
        // Verify the signer is our trusted oracle
        require(signer == trustedOracle, "Invalid signature");
        
        uint256[] memory tokenIds = new uint256[](quantity);
        
        // Mint each NFT
        for (uint256 i = 0; i < quantity; i++) {
            uint256 tokenId = _currentTokenId;
            _currentTokenId++;

            // Mint the NFT
            _safeMint(to, tokenId);
            
            // Set the token URI based on rarity
            string memory tokenUriForRarity = rarityToURI[rarities[i]];
            require(bytes(tokenUriForRarity).length > 0, "URI not set for this rarity");
            _setTokenURI(tokenId, tokenUriForRarity);
            
            // Set the rarity
            tokenRarity[tokenId] = rarities[i];
            emit RaritySet(tokenId, rarities[i]);
            
            emit Minted(to, tokenId, rarities[i]);
            
            tokenIds[i] = tokenId;
        }
        
        emit BatchMinted(to, tokenIds, quantity);
        
        return tokenIds;
    }
    
    /**
     * @dev For backward compatibility - Single mint function
     * @param to The address to mint the NFT to
     * @param signature The signature from trusted oracle containing rarity information
     * @param nonce Unique nonce to prevent replay attacks
     * @return tokenId The ID of the minted token
     */
    function mintInternal(address to, bytes memory signature, bytes32 nonce) external returns (uint256) {
        uint256[] memory tokenIds = this.batchMintInternal(to, signature, nonce, 1);
        return tokenIds[0];
    }

    /**
     * @dev Helper function to verify and extract rarities from signature
     * @param recipient The address receiving the NFTs
     * @param nonce Unique nonce to prevent replay attacks
     * @param quantity Number of NFTs being minted
     * @param signature The signature from trusted oracle
     * @return rarities Array of rarities extracted from the signature
     * @return signer The address that signed the message
     */
    function verifyAndExtractRarities(
        address recipient, 
        bytes32 nonce, 
        uint256 quantity,
        bytes memory signature
    ) internal pure returns (Rarity[] memory rarities, address signer) {
        // The first bytes of the signature contain the rarity values (0-4)
        require(signature.length >= 65 + quantity, "Signature too short");
        
        // Extract rarities from the first bytes
        rarities = new Rarity[](quantity);
        for (uint256 i = 0; i < quantity; i++) {
            rarities[i] = Rarity(uint8(signature[i]));
            require(uint8(rarities[i]) <= uint8(Rarity.LEGENDARY), "Invalid rarity value");
        }
        
        // Extract the actual signature (skip the rarity bytes)
        bytes memory actualSignature = new bytes(65);
        for (uint i = 0; i < 65; i++) {
            actualSignature[i] = signature[i + quantity];
        }
        
        // Verify the signature
        // Include recipient, nonce, quantity, and encoded rarities in the message
        bytes32 messageHash = keccak256(abi.encodePacked(recipient, nonce, quantity, encodedRarities(rarities)));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        signer = ECDSA.recover(ethSignedMessageHash, actualSignature);
        
        return (rarities, signer);
    }
    
    /**
     * @dev Helper function to encode rarities for signature verification
     * @param rarities Array of rarities to encode
     * @return encoded Encoded rarities as bytes
     */
    function encodedRarities(Rarity[] memory rarities) internal pure returns (bytes memory) {
        bytes memory encoded = new bytes(rarities.length);
        for (uint256 i = 0; i < rarities.length; i++) {
            encoded[i] = bytes1(uint8(rarities[i]));
        }
        return encoded;
    }
    
    /**
     * @dev Get the current token ID
     */
    function getCurrentTokenId() external view returns (uint256) {
        return _currentTokenId;
    }
    
    /**
     * @dev Check if a token exists
     * @param tokenId The token ID to check
     * @return Whether the token exists
     */
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }
    
    /**
     * @dev Check if a nonce has been used
     * @param nonce The nonce to check
     * @return Whether the nonce has been used
     */
    function isNonceUsed(bytes32 nonce) external view returns (bool) {
        return usedNonces[keccak256(abi.encodePacked(nonce))];
    }
    
    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }
    
    function supportsInterface(bytes4 interfaceId) public view override(ERC721Enumerable, ERC721URIStorage, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId) || ERC2981.supportsInterface(interfaceId);
    }
    
    function _update(address to, uint256 tokenId, address auth) internal override(ERC721, ERC721Enumerable) returns (address) {
        return super._update(to, tokenId, auth);
    }
    
    function _increaseBalance(address account, uint128 value) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }
}