// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MRTCollection.sol";
import "../src/MRTPresale.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// Mock MRT Token
contract MockMRTToken is ERC20 {
    constructor() ERC20("Mock MRT Token", "MMRT") {
        _mint(msg.sender, 1_000_000 * 10**18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock USDT Token
contract MockUSDTToken is ERC20 {
    constructor() ERC20("Mock USDT Token", "MUSDT") {
        _mint(msg.sender, 1_000_000 * 10**6); // USDT has 6 decimals
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MRTProperTest is Test {
    // Contracts
    MRTCollection public nftCollection;
    MRTPresale public presale;
    MockMRTToken public mrtToken;
    MockUSDTToken public usdtToken;

    // Addresses
    address public owner;
    address public trustedOracle;
    address public stakingContract;
    address public marketingWallet;
    address public vestingWallet;
    address public daoContract;
    address public user1;
    address public user2;
    address public user3;

    // Oracle private key (for signing)
    uint256 private oraclePrivateKey;

    // Presale variables
    uint256 public publicPresaleId;
    uint256 public privatePresaleId;
    bytes32 public merkleRoot;

    // Constants
    uint256 constant ETH_PRICE = 0.1 ether; // Base price 0.1 ETH
    uint256 constant MRT_PRICE = 100 * 10**18; // Base price 100 MRT tokens
    uint256 constant USDT_PRICE = 100 * 10**6; // Base price 100 USDT
    uint256 constant PUBLIC_PRESALE_MAX_SUPPLY = 100;
    uint256 constant PRIVATE_PRESALE_MAX_SUPPLY = 50;
    uint256 constant MAX_PER_ADDRESS = 5;

    function setUp() public {
        // Setup private key for trusted oracle
        oraclePrivateKey = 0x12345678901234567890123456789012; // Fixed key for deterministic testing
        trustedOracle = vm.addr(oraclePrivateKey);

        // Setup accounts
        owner = makeAddr("owner");
        stakingContract = makeAddr("stakingContract");
        marketingWallet = makeAddr("marketingWallet");
        vestingWallet = makeAddr("vestingWallet");
        daoContract = makeAddr("daoContract");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        vm.startPrank(owner);
        
        // Deploy tokens
        mrtToken = new MockMRTToken();
        usdtToken = new MockUSDTToken();

        // Deploy NFT Collection
        nftCollection = new MRTCollection(
            "ipfs://baseTokenURI/",
            address(mrtToken),
            trustedOracle,
            daoContract,
            500 // 5% royalty
        );

        // Set rarity URIs
        nftCollection.setRarityURI(MRTCollection.Rarity.COMMON, "ipfs://baseTokenURI/common");
        nftCollection.setRarityURI(MRTCollection.Rarity.UNCOMMON, "ipfs://baseTokenURI/uncommon");
        nftCollection.setRarityURI(MRTCollection.Rarity.RARE, "ipfs://baseTokenURI/rare");
        nftCollection.setRarityURI(MRTCollection.Rarity.EPIC, "ipfs://baseTokenURI/epic");
        nftCollection.setRarityURI(MRTCollection.Rarity.LEGENDARY, "ipfs://baseTokenURI/legendary");

        // Deploy presale
        presale = new MRTPresale(
            address(nftCollection),
            address(mrtToken),
            address(usdtToken),
            trustedOracle,
            stakingContract,
            marketingWallet,
            vestingWallet,
            daoContract
        );

        // Set presale contract in NFT collection
        nftCollection.setContractAddresses(address(presale), daoContract);

        // Send tokens to users
        mrtToken.transfer(user1, 1000 * 10**18);
        mrtToken.transfer(user2, 1000 * 10**18);
        mrtToken.transfer(user3, 1000 * 10**18);
        
        usdtToken.transfer(user1, 1000 * 10**6);
        usdtToken.transfer(user2, 1000 * 10**6);
        usdtToken.transfer(user3, 1000 * 10**6);

        // Enable USDT minting
        presale.toggleUSDTMint(true);

        // Create merkle tree for whitelist (simple version for test)
        address[] memory whitelistedAddresses = new address[](2);
        whitelistedAddresses[0] = user1;
        whitelistedAddresses[1] = user2;
        merkleRoot = computeMerkleRoot(whitelistedAddresses);

        // Setup presales with future start time
        uint256 futureStartTime = block.timestamp + 100;
        uint256 endTime = futureStartTime + 7 days;
        
        // Create public presale
        publicPresaleId = presale.createPresale(
            futureStartTime,
            endTime,
            PUBLIC_PRESALE_MAX_SUPPLY,
            ETH_PRICE,
            MRT_PRICE,
            USDT_PRICE,
            0.01 ether,
            10 * 10**18,
            10 * 10**6,
            bytes32(0), // No merkle root for public
            MAX_PER_ADDRESS,
            false // Not private
        );

        // Create private presale
        privatePresaleId = presale.createPresale(
            futureStartTime,
            endTime,
            PRIVATE_PRESALE_MAX_SUPPLY,
            ETH_PRICE,
            MRT_PRICE,
            USDT_PRICE,
            0.01 ether,
            10 * 10**18,
            10 * 10**6,
            merkleRoot, // With merkle root
            MAX_PER_ADDRESS,
            true // Private
        );
        
        vm.stopPrank();

        // Move to presale start time
        vm.warp(futureStartTime + 10);
    }

    // Compute merkle root from list of addresses
    function computeMerkleRoot(address[] memory addresses) public pure returns (bytes32) {
        // Sort addresses to ensure consistent ordering
        // (not necessary with just 2 addresses but good practice)
        sortAddresses(addresses);
        
        // Create leaf nodes
        bytes32[] memory leaves = new bytes32[](addresses.length);
        for (uint i = 0; i < addresses.length; i++) {
            leaves[i] = keccak256(abi.encodePacked(addresses[i]));
        }
        
        // With just 2 addresses, the root is the hash of the concatenated leaves
        // Important: We sort the leaves before hashing to ensure consistency
        bytes32 leaf0 = leaves[0];
        bytes32 leaf1 = leaves[1];
        
        if (uint256(leaf0) > uint256(leaf1)) {
            (leaf0, leaf1) = (leaf1, leaf0);
        }
        
        return keccak256(abi.encodePacked(leaf0, leaf1));
    }

    // Helper to sort addresses
    function sortAddresses(address[] memory addrs) internal pure {
        // Simple bubble sort for small arrays
        for (uint i = 0; i < addrs.length - 1; i++) {
            for (uint j = 0; j < addrs.length - i - 1; j++) {
                if (uint160(addrs[j]) > uint160(addrs[j + 1])) {
                    (addrs[j], addrs[j + 1]) = (addrs[j + 1], addrs[j]);
                }
            }
        }
    }

    // Get merkle proof for a specific address
    function getMerkleProof(address addr) public view returns (bytes32[] memory) {
        // Create an array of the whitelisted addresses in the same order as when creating the root
        address[] memory whitelistedAddresses = new address[](2);
        whitelistedAddresses[0] = user1;
        whitelistedAddresses[1] = user2;
        
        // Sort addresses (same as we did when creating root)
        sortAddresses(whitelistedAddresses);
        
        // Create leaf nodes
        bytes32[] memory leaves = new bytes32[](whitelistedAddresses.length);
        for (uint i = 0; i < whitelistedAddresses.length; i++) {
            leaves[i] = keccak256(abi.encodePacked(whitelistedAddresses[i]));
        }
        
        // Find the index of the target address
        uint256 index = type(uint256).max;
        for (uint i = 0; i < whitelistedAddresses.length; i++) {
            if (whitelistedAddresses[i] == addr) {
                index = i;
                break;
            }
        }
        
        // Return empty proof if address not found
        if (index == type(uint256).max) {
            return new bytes32[](0);
        }
        
        // For a simple 2-node tree, the proof is just the other leaf
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaves[index == 0 ? 1 : 0];
        
        return proof;
    }
        
    // Create a properly signed signature for a single mint
    function createSingleMintSignature(
        address recipient, 
        bytes32 nonce,
        MRTCollection.Rarity rarity
    ) public returns (bytes memory) {
        // Using batch mint signature with quantity=1
        MRTCollection.Rarity[] memory rarities = new MRTCollection.Rarity[](1);
        rarities[0] = rarity;
        return createBatchMintSignature(recipient, nonce, 1, rarities);
    }

    // Create a properly signed signature for batch mint
    function createBatchMintSignature(
        address recipient, 
        bytes32 nonce,
        uint256 quantity,
        MRTCollection.Rarity[] memory rarities
    ) public returns (bytes memory) {
        require(rarities.length == quantity, "Rarities array length must match quantity");
        
        // Create signature with first bytes being the rarities
        bytes memory sig = new bytes(quantity + 65);
        
        // Set rarities bytes
        bytes memory encodedRarities = new bytes(quantity);
        for (uint i = 0; i < quantity; i++) {
            sig[i] = bytes1(uint8(rarities[i]));
            encodedRarities[i] = bytes1(uint8(rarities[i]));
        }
        
        // Create message hash as expected by the contract
        bytes32 messageHash = keccak256(abi.encodePacked(recipient, nonce, quantity, encodedRarities));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        
        // Sign the message with oracle's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // Copy the signature bytes after the rarities bytes
        for (uint i = 0; i < 65; i++) {
            sig[i + quantity] = signature[i];
        }
        
        return sig;
    }

    // Test whitelist eligibility
    function testWhitelistEligibility() public {
        bytes32[] memory proofUser1 = getMerkleProof(user1);
        bytes32[] memory proofUser2 = getMerkleProof(user2);
        bytes32[] memory emptyProof = new bytes32[](0);
        
        bool user1Eligible = presale.isEligibleForPrivatePresale(privatePresaleId, user1, proofUser1);
        bool user2Eligible = presale.isEligibleForPrivatePresale(privatePresaleId, user2, proofUser2);
        bool user3Eligible = presale.isEligibleForPrivatePresale(privatePresaleId, user3, emptyProof);
        
        assertTrue(user1Eligible, "User1 should be eligible");
        assertTrue(user2Eligible, "User2 should be eligible");
        assertFalse(user3Eligible, "User3 should not be eligible");
    }

    // Test single mint with ETH in public presale
    function test_SingleMintWithETHInPublicPresale() public {
        bytes32 nonce = keccak256(abi.encodePacked("nonce1"));
        bytes memory signature = createSingleMintSignature(user3, nonce, MRTCollection.Rarity.COMMON);
        bytes32[] memory emptyProof = new bytes32[](0);
        
        uint256 currentPrice = presale.getCurrentPrice(publicPresaleId);
        
        vm.deal(user3, currentPrice);
        vm.prank(user3);
        presale.batchMintWithETH{value: currentPrice}(publicPresaleId, emptyProof, signature, nonce, 1);
        
        assertEq(nftCollection.balanceOf(user3), 1, "User3 should have 1 NFT");
    }

    // Test batch mint with ETH in public presale
    function test_BatchMintWithETHInPublicPresale() public {
        bytes32 nonce = keccak256(abi.encodePacked("nonce2"));
        
        uint256 batchSize = 3;
        MRTCollection.Rarity[] memory rarities = new MRTCollection.Rarity[](batchSize);
        rarities[0] = MRTCollection.Rarity.COMMON;
        rarities[1] = MRTCollection.Rarity.UNCOMMON;
        rarities[2] = MRTCollection.Rarity.RARE;
        
        bytes memory signature = createBatchMintSignature(user3, nonce, batchSize, rarities);
        bytes32[] memory emptyProof = new bytes32[](0);
        
        // Since batch minting increases the price for each NFT sequentially,
        // we need to calculate the total price for all NFTs in the batch
        uint256 startingPrice = presale.getCurrentPrice(privatePresaleId);
        uint256 totalPrice = startingPrice * batchSize;
        
        vm.deal(user3, totalPrice);
        vm.prank(user3);
        presale.batchMintWithETH{value: totalPrice}(publicPresaleId, emptyProof, signature, nonce, batchSize);
        
        assertEq(nftCollection.balanceOf(user3), batchSize, "User3 should have 3 NFTs");
    }

    // Test single mint with MRT in public presale
    function test_SingleMintWithMRTInPublicPresale() public {
        bytes32 nonce = keccak256(abi.encodePacked("nonce3"));
        bytes memory signature = createSingleMintSignature(user3, nonce, MRTCollection.Rarity.RARE);
        bytes32[] memory emptyProof = new bytes32[](0);
        
        uint256 currentMRTPrice = presale.getCurrentMRTPrice(publicPresaleId);
        
        vm.prank(user3);
        mrtToken.approve(address(presale), currentMRTPrice);
        
        vm.prank(user3);
        presale.batchMintWithMRT(publicPresaleId, emptyProof, signature, nonce, 1);
        
        assertEq(nftCollection.balanceOf(user3), 1, "User3 should have 1 NFT");
    }

    // Test batch mint with MRT in public presale
    function test_BatchMintWithMRTInPublicPresale() public {
        bytes32 nonce = keccak256(abi.encodePacked("nonce4"));
        
        uint256 batchSize = 3;
        MRTCollection.Rarity[] memory rarities = new MRTCollection.Rarity[](batchSize);
        rarities[0] = MRTCollection.Rarity.EPIC;
        rarities[1] = MRTCollection.Rarity.LEGENDARY;
        rarities[2] = MRTCollection.Rarity.RARE;
        
        bytes memory signature = createBatchMintSignature(user3, nonce, batchSize, rarities);
        bytes32[] memory emptyProof = new bytes32[](0);
        
        // Calculate total MRT price with increases
        uint256 startingMRTPrice = presale.getCurrentMRTPrice(publicPresaleId);
        uint256 totalMRTPrice = 0;
        for (uint256 i = 0; i < batchSize; i++) {
            totalMRTPrice += startingMRTPrice + (10 * 10**18 * i); // 10 MRT increase per mint
        }
        
        vm.prank(user3);
        mrtToken.approve(address(presale), totalMRTPrice);
        
        vm.prank(user3);
        presale.batchMintWithMRT(publicPresaleId, emptyProof, signature, nonce, batchSize);
        
        assertEq(nftCollection.balanceOf(user3), batchSize, "User3 should have 3 NFTs");
    }

    // Test single mint with ETH in private presale
    function test_SingleMintWithETHInPrivatePresale() public {
        bytes32 nonce = keccak256(abi.encodePacked("nonce5"));
        bytes memory signature = createSingleMintSignature(user1, nonce, MRTCollection.Rarity.COMMON);
        bytes32[] memory proofUser1 = getMerkleProof(user1);
        
        uint256 currentPrice = presale.getCurrentPrice(privatePresaleId);
        
        vm.deal(user1, currentPrice);
        vm.prank(user1);
        presale.batchMintWithETH{value: currentPrice}(privatePresaleId, proofUser1, signature, nonce, 1);
        
        assertEq(nftCollection.balanceOf(user1), 1, "User1 should have 1 NFT");
    }

    // Test batch mint with ETH in private presale
    function test_BatchMintWithETHInPrivatePresale() public {
        bytes32 nonce = keccak256(abi.encodePacked("nonce6"));
        
        uint256 batchSize = 3;
        MRTCollection.Rarity[] memory rarities = new MRTCollection.Rarity[](batchSize);
        rarities[0] = MRTCollection.Rarity.COMMON;
        rarities[1] = MRTCollection.Rarity.UNCOMMON;
        rarities[2] = MRTCollection.Rarity.RARE;
        
        bytes memory signature = createBatchMintSignature(user1, nonce, batchSize, rarities);
        bytes32[] memory proofUser1 = getMerkleProof(user1);
        
        uint256 startingPrice = presale.getCurrentPrice(privatePresaleId);
        uint256 totalPrice = startingPrice * batchSize;
        
        vm.deal(user1, totalPrice);
        vm.prank(user1);
        presale.batchMintWithETH{value: totalPrice}(privatePresaleId, proofUser1, signature, nonce, batchSize);
        
        assertEq(nftCollection.balanceOf(user1), batchSize, "User1 should have 3 NFTs");
    }

    // Test non-eligible user in private presale
    function test_NonEligibleUserInPrivatePresale() public {
        bytes32 nonce = keccak256(abi.encodePacked("nonce7"));
        bytes memory signature = createSingleMintSignature(user3, nonce, MRTCollection.Rarity.COMMON);
        bytes32[] memory emptyProof = new bytes32[](0);
        
        uint256 currentPrice = presale.getCurrentPrice(privatePresaleId);
        
        vm.deal(user3, currentPrice);
        vm.prank(user3);
        vm.expectRevert("Not eligible for private presale");
        presale.batchMintWithETH{value: currentPrice}(privatePresaleId, emptyProof, signature, nonce, 1);
    }

    // Test max per address limit
    function test_MaxPerAddressLimit() public {
        bytes32[] memory emptyProof = new bytes32[](0);
        
        // Calculate total ETH needed with price increases
        uint256 totalEthNeeded = 0;
        for (uint256 i = 0; i < MAX_PER_ADDRESS; i++) {
            uint256 currentPrice = ETH_PRICE + (0.01 ether * i); // 0.01 ETH increase per mint
            totalEthNeeded += currentPrice;
        }
        // Add extra ETH for the failing test
        totalEthNeeded += ETH_PRICE + (0.01 ether * MAX_PER_ADDRESS);
        
        vm.deal(user3, totalEthNeeded);
        vm.startPrank(user3);
        
        // Mint MAX_PER_ADDRESS NFTs one by one
        for (uint256 i = 0; i < MAX_PER_ADDRESS; i++) {
            bytes32 nonce = keccak256(abi.encodePacked("max_limit_", i));
            bytes memory signature = createSingleMintSignature(user3, nonce, MRTCollection.Rarity.COMMON);
            uint256 currentPrice = presale.getCurrentPrice(publicPresaleId);
            presale.batchMintWithETH{value: currentPrice}(publicPresaleId, emptyProof, signature, nonce, 1);
        }
        
        vm.stopPrank();
        
        assertEq(nftCollection.balanceOf(user3), MAX_PER_ADDRESS, "User3 should have MAX_PER_ADDRESS NFTs");
        
        // Try to mint one more - should fail
        bytes32 nonce = keccak256(abi.encodePacked("max_limit_exceed"));
        bytes memory signature = createSingleMintSignature(user3, nonce, MRTCollection.Rarity.COMMON);
        
        uint256 currentPrice = presale.getCurrentPrice(publicPresaleId);
        
        vm.prank(user3);
        vm.expectRevert("Exceeds max per address");
        presale.batchMintWithETH{value: currentPrice}(publicPresaleId, emptyProof, signature, nonce, 1);
    }

    // Test nonce reuse prevention
    function test_NonceReusePrevention() public {
        bytes32 nonce = keccak256(abi.encodePacked("reuse_nonce"));
        bytes memory signature = createSingleMintSignature(user3, nonce, MRTCollection.Rarity.COMMON);
        bytes32[] memory emptyProof = new bytes32[](0);
        
        // First mint should succeed
        uint256 firstPrice = presale.getCurrentPrice(publicPresaleId);
        uint256 secondPrice = firstPrice + 0.01 ether; // Price after first mint
        
        vm.deal(user3, firstPrice + secondPrice); // Fund for both attempts
        
        vm.prank(user3);
        presale.batchMintWithETH{value: firstPrice}(publicPresaleId, emptyProof, signature, nonce, 1);
        
        // Second mint with same nonce should fail
        vm.prank(user3);
        vm.expectRevert("Nonce already used");
        presale.batchMintWithETH{value: secondPrice}(publicPresaleId, emptyProof, signature, nonce, 1);
    }

    // Test presale max supply limit
    function test_PresaleMaxSupplyLimit() public {
        // Create a small presale with future start time
        uint256 smallMaxSupply = 2;
        vm.prank(owner);
        uint256 smallPresaleId = presale.createPresale(
            block.timestamp + 1, // Future start time
            block.timestamp + 10 + 100 days,
            smallMaxSupply, // Only 2 NFTs
            ETH_PRICE, 
            MRT_PRICE,
            USDT_PRICE,
            0, // No increase for this test
            0,
            0,
            bytes32(0), // No merkle root
            MAX_PER_ADDRESS,
            false // Not private
        );
        
        // Move time to start the presale
        vm.warp(block.timestamp + 15);
        
        // Mint up to max supply (no price increase for this presale)
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.deal(user3, ETH_PRICE * 3);
        vm.startPrank(user3);
        
        for (uint256 i = 0; i < smallMaxSupply; i++) {
            bytes32 nonce = keccak256(abi.encodePacked("supply_limit_", i));
            bytes memory signature = createSingleMintSignature(user3, nonce, MRTCollection.Rarity.COMMON);
            uint256 currentPrice = presale.getCurrentPrice(smallPresaleId);
            presale.batchMintWithETH{value: currentPrice}(smallPresaleId, emptyProof, signature, nonce, 1);
        }
        
        // Try to mint one more - should fail
        bytes32 nonce = keccak256(abi.encodePacked("supply_limit_exceed"));
        bytes memory signature = createSingleMintSignature(user3, nonce, MRTCollection.Rarity.COMMON);
        uint256 currentPrice = presale.getCurrentPrice(smallPresaleId);
        
        vm.expectRevert("Exceeds presale supply");
        presale.batchMintWithETH{value: currentPrice}(smallPresaleId, emptyProof, signature, nonce, 1);
        
        vm.stopPrank();
    }
    
    // Test batch mint with USDT in public presale
    function test_BatchMintWithUSDTInPublicPresale() public {
        bytes32 nonce = keccak256(abi.encodePacked("nonce_usdt"));
        
        uint256 batchSize = 2;
        MRTCollection.Rarity[] memory rarities = new MRTCollection.Rarity[](batchSize);
        rarities[0] = MRTCollection.Rarity.EPIC;
        rarities[1] = MRTCollection.Rarity.RARE;
        
        bytes memory signature = createBatchMintSignature(user3, nonce, batchSize, rarities);
        bytes32[] memory emptyProof = new bytes32[](0);
        
        // Calculate total USDT price with increases
        uint256 startingUSDTPrice = presale.getCurrentUSDTPrice(publicPresaleId);
        uint256 totalUSDTPrice = 0;
        for (uint256 i = 0; i < batchSize; i++) {
            totalUSDTPrice += startingUSDTPrice + (10 * 10**6 * i); // 10 USDT increase per mint
        }
        
        vm.prank(user3);
        usdtToken.approve(address(presale), totalUSDTPrice);
        
        vm.prank(user3);
        presale.batchMintWithUSDT(publicPresaleId, emptyProof, signature, nonce, batchSize);
        
        assertEq(nftCollection.balanceOf(user3), batchSize, "User3 should have 2 NFTs");
    }
    
    // Test single mint with USDT in private presale
    function test_SingleMintWithUSDTInPrivatePresale() public {
        bytes32 nonce = keccak256(abi.encodePacked("nonce_usdt_private"));
        bytes memory signature = createSingleMintSignature(user1, nonce, MRTCollection.Rarity.LEGENDARY);
        bytes32[] memory proofUser1 = getMerkleProof(user1);
        
        uint256 currentUSDTPrice = presale.getCurrentUSDTPrice(privatePresaleId);
        
        vm.prank(user1);
        usdtToken.approve(address(presale), currentUSDTPrice);
        
        vm.prank(user1);
        presale.batchMintWithUSDT(privatePresaleId, proofUser1, signature, nonce, 1);
        
        assertEq(nftCollection.balanceOf(user1), 1, "User1 should have 1 NFT");
    }
}