// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MRTCollection.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// Mock MRT token for testing
contract MockMRTToken is ERC20 {
    constructor() ERC20("Mock MRT Token", "MRT") {
        _mint(msg.sender, 1000000 * 10**18);
    }
}

contract MRTCollectionTest is Test {
    MRTCollection public collection;
    MockMRTToken public mrtToken;
    
    address public owner = makeAddr("owner");
    address public daoContract = makeAddr("dao");
    address public trustedOracle = makeAddr("oracle");
    address public user = makeAddr("user");
    address public presaleContract = makeAddr("presale");
    
    uint256 public trustedOraclePrivateKey;
    
    // Constants
    string public name = "MRT Collection";
    string public symbol = "MRTC";
    string public baseTokenURI = "https://metadata.example.com/";
    uint96 public royaltyPercentage = 500; // 5%
    
    function setUp() public {
        // Set the block timestamp to something realistic
        vm.warp(1680000000);
        
        // Create oracle keypair
        trustedOraclePrivateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        trustedOracle = vm.addr(trustedOraclePrivateKey);
        
        // Deploy the mock MRT token
        vm.startPrank(owner);
        mrtToken = new MockMRTToken();
        
        // Deploy the collection contract
        collection = new MRTCollection(
            baseTokenURI,
            address(mrtToken),
            trustedOracle,
            daoContract,
            royaltyPercentage
        );
        
        // Set up presale contract
        collection.setContractAddresses(presaleContract, daoContract);
        
        // Set up rarity URIs (without baseURI prefix, as the contract will add it)
        collection.setRarityURI(MRTCollection.Rarity.COMMON, "common.json");
        collection.setRarityURI(MRTCollection.Rarity.UNCOMMON, "uncommon.json");
        collection.setRarityURI(MRTCollection.Rarity.RARE, "rare.json");
        collection.setRarityURI(MRTCollection.Rarity.EPIC, "epic.json");
        collection.setRarityURI(MRTCollection.Rarity.LEGENDARY, "legendary.json");
        
        vm.stopPrank();
    }
    
    function testMintToken() public {
        // Mint a token with LEGENDARY rarity
        _mintTokenWithRarity(user, MRTCollection.Rarity.LEGENDARY);
        
        // Verify token was minted correctly
        assertEq(collection.ownerOf(0), user);
        assertEq(uint(collection.tokenRarity(0)), uint(MRTCollection.Rarity.LEGENDARY));
        assertEq(collection.tokenURI(0), "https://metadata.example.com/legendary.json");
    }
    
    function testMintMultipleTokensWithDifferentRarities() public {
        // Mint tokens with different rarities
        _mintTokenWithRarity(user, MRTCollection.Rarity.COMMON);
        _mintTokenWithRarity(user, MRTCollection.Rarity.UNCOMMON);
        _mintTokenWithRarity(user, MRTCollection.Rarity.RARE);
        _mintTokenWithRarity(user, MRTCollection.Rarity.EPIC);
        _mintTokenWithRarity(user, MRTCollection.Rarity.LEGENDARY);
        
        // Verify all tokens
        assertEq(collection.ownerOf(0), user);
        assertEq(collection.ownerOf(1), user);
        assertEq(collection.ownerOf(2), user);
        assertEq(collection.ownerOf(3), user);
        assertEq(collection.ownerOf(4), user);
        
        // Verify rarities
        assertEq(uint(collection.tokenRarity(0)), uint(MRTCollection.Rarity.COMMON));
        assertEq(uint(collection.tokenRarity(1)), uint(MRTCollection.Rarity.UNCOMMON));
        assertEq(uint(collection.tokenRarity(2)), uint(MRTCollection.Rarity.RARE));
        assertEq(uint(collection.tokenRarity(3)), uint(MRTCollection.Rarity.EPIC));
        assertEq(uint(collection.tokenRarity(4)), uint(MRTCollection.Rarity.LEGENDARY));
        
        // Verify token URIs (with baseURI prefix)
        assertEq(collection.tokenURI(0), "https://metadata.example.com/common.json");
        assertEq(collection.tokenURI(1), "https://metadata.example.com/uncommon.json");
        assertEq(collection.tokenURI(2), "https://metadata.example.com/rare.json");
        assertEq(collection.tokenURI(3), "https://metadata.example.com/epic.json");
        assertEq(collection.tokenURI(4), "https://metadata.example.com/legendary.json");
    }
    
    function testNonceReuse() public {
        // Generate a nonce
        bytes32 nonce = keccak256(abi.encodePacked(block.timestamp, user, "salt"));
        
        // Mint first token
        uint256 tokenId = collection.getCurrentTokenId();
        bytes memory signature = _createSignatureWithRarity(
            trustedOraclePrivateKey,
            tokenId,
            MRTCollection.Rarity.LEGENDARY,
            nonce,
            user
        );
        
        vm.prank(presaleContract);
        collection.mintInternal(user, signature, nonce);
        
        // Try to reuse the same nonce - should fail
        tokenId = collection.getCurrentTokenId();
        signature = _createSignatureWithRarity(
            trustedOraclePrivateKey,
            tokenId,
            MRTCollection.Rarity.LEGENDARY,
            nonce,
            user
        );
        
        vm.prank(presaleContract);
        vm.expectRevert("Nonce already used");
        collection.mintInternal(user, signature, nonce);
    }
    
    function testMaxSupplyReduce() public {
        // Check initial max supply
        uint256 initialMaxSupply = collection.maxSupply();
        
        // Mint a token
        _mintTokenWithRarity(user, MRTCollection.Rarity.COMMON);
        
        // Verify max supply was reduced by 1
        assertEq(collection.maxSupply(), initialMaxSupply - 1);
    }
    
    function testManualMaxSupplyReduction() public {
        // Check initial max supply
        uint256 initialMaxSupply = collection.maxSupply();
        
        // Reduce max supply by 100
        vm.prank(owner);
        bool success = collection.reduceMaxSupply(100);
        
        // Verify reduction was successful
        assertTrue(success);
        assertEq(collection.maxSupply(), initialMaxSupply - 100);
    }
    
    function testInvalidRaritySignature() public {
        uint256 tokenId = collection.getCurrentTokenId();
        bytes32 nonce = keccak256(abi.encodePacked(block.timestamp, user, "salt"));
        
        // Using an extremely short signature (definitely invalid)
        bytes memory signature = new bytes(3);
        
        // Try to mint with invalid signature - should fail
        vm.prank(presaleContract);
        vm.expectRevert("Signature too short");
        collection.mintInternal(user, signature, nonce);
    }
    
    function testMintFromUnauthorizedAddress() public {
        // Try to mint from an unauthorized address
        bytes32 nonce = keccak256(abi.encodePacked(block.timestamp, user, "salt"));
        uint256 tokenId = collection.getCurrentTokenId();
        bytes memory signature = _createSignatureWithRarity(
            trustedOraclePrivateKey,
            tokenId,
            MRTCollection.Rarity.LEGENDARY,
            nonce,
            user
        );
        
        // This should fail as the sender is neither owner nor presale contract
        vm.prank(user);
        vm.expectRevert("Caller is not authorized to mint");
        collection.mintInternal(user, signature, nonce);
    }
    
    /*
     * Helper functions
     */
    
    function _mintTokenWithRarity(address recipient, MRTCollection.Rarity rarity) internal {
        // Generate a unique nonce
        bytes32 nonce = keccak256(abi.encodePacked(block.timestamp, recipient, "salt", collection.getCurrentTokenId()));
        
        // Create signature with rarity
        uint256 tokenId = collection.getCurrentTokenId();
        bytes memory signature = _createSignatureWithRarity(
            trustedOraclePrivateKey,
            tokenId,
            rarity,
            nonce,
            recipient
        );
        
        // Mint the token
        vm.prank(presaleContract);
        collection.mintInternal(recipient, signature, nonce);
    }
    
    function _createSignatureWithRarity(
        uint256 privateKey,
        uint256 tokenId,
        MRTCollection.Rarity rarity,
        bytes32 nonce,
        address recipient
    ) internal pure returns (bytes memory) {
        // Create the message hash exactly as in the contract
        bytes32 messageHash = keccak256(abi.encodePacked(tokenId, uint8(rarity), nonce, recipient));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        
        // Sign the message hash
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedMessageHash);
        bytes memory standardSignature = abi.encodePacked(r, s, v);
        
        // Create the final signature with rarity as the first byte
        bytes memory finalSignature = new bytes(standardSignature.length + 1);
        
        // Set the first byte to the rarity value
        finalSignature[0] = bytes1(uint8(rarity));
        
        // Copy the rest of the signature
        for (uint i = 0; i < standardSignature.length; i++) {
            finalSignature[i + 1] = standardSignature[i];
        }
        
        return finalSignature;
    }
}