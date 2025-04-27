// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MRTCollection} from "../src/MRTCollection.sol";
import {MRTPresale} from "../src/MRTPresale.sol";

/**
 * @title DeployMRTScript
 * @dev Deployment script for MRT ecosystem contracts on Anvil for dev testing
 */
contract DeployMRTScript is Script {
    // Anvil default addresses (first 10 accounts)
    // Each with 10000 ETH by default
    address private constant ANVIL_ACCOUNT_0 = 0xc2A35f8d2c9d36e4e93D2897fD1845b2727159f6; // Default deployer
    address private constant ANVIL_ACCOUNT_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address private constant ANVIL_ACCOUNT_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address private constant ANVIL_ACCOUNT_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address private constant ANVIL_ACCOUNT_4 = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    address private constant ANVIL_ACCOUNT_5 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;
    address private constant ANVIL_ACCOUNT_6 = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;
    address private constant ANVIL_ACCOUNT_7 = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955;
    address private constant ANVIL_ACCOUNT_8 = 0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f;
    address private constant ANVIL_ACCOUNT_9 = 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720;
    
    // Role assignments
    address private constant DEPLOYER = ANVIL_ACCOUNT_0;
    address private constant TRUSTED_ORACLE = ANVIL_ACCOUNT_1;
    address private constant STAKING_CONTRACT = ANVIL_ACCOUNT_2; // For simplicity in dev
    address private constant MARKETING_WALLET = ANVIL_ACCOUNT_3;
    address private constant VESTING_WALLET = ANVIL_ACCOUNT_4;
    address private constant DAO_CONTRACT = ANVIL_ACCOUNT_5;

    // Contract instances
    ERC20Mock public mrtToken;
    ERC20Mock public usdtToken;
    MRTCollection public nftCollection;
    MRTPresale public presaleContract;

    // Settings for deployment
    string private constant BASE_URI = "";
    uint96 private constant ROYALTY_PERCENTAGE = 500; // 5%
    
    // Presale configuration
    uint256 private constant MAX_SUPPLY = 1000;
    uint256 private constant BASE_PRICE = 0.05 ether;
    uint256 private constant MRT_BASE_PRICE = 5000 ether; // Mock MRT amount (with 18 decimals)
    uint256 private constant PRICE_INCREASE_RATE = 0.001 ether;
    uint256 private constant MRT_PRICE_INCREASE_RATE = 10 ether;
    uint256 private constant MAX_PER_ADDRESS = 10;

    function run() external {
        // For Anvil, we can use the default private key of account 0
        // Anvil's first private key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
        uint256 deployerPrivateKey = 0xadae6972a8485ae2c033aa4c1f8c5816057d31c6944f060cac47daabff69ba95;
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy mock tokens
        console.log("Deploying mock MRT token...");
        mrtToken = new ERC20Mock();
        // Initialize with name, symbol, and initial supply to deployer
        mrtToken.mint(ANVIL_ACCOUNT_0, 10000000 ether);
        console.log("MRT Token deployed at: ", address(mrtToken));

        // 2. Deploy NFT Collection
        console.log("Deploying NFT Collection...");
        nftCollection = new MRTCollection(
            BASE_URI,
            address(mrtToken),
            TRUSTED_ORACLE,
            DAO_CONTRACT,
            ROYALTY_PERCENTAGE
        );
        console.log("NFT Collection deployed at: ", address(nftCollection));

        // 3. Deploy Presale Contract
        console.log("Deploying Presale Contract...");
        presaleContract = new MRTPresale(
            address(nftCollection),
            address(mrtToken),
            address(usdtToken),
            TRUSTED_ORACLE,
            STAKING_CONTRACT,
            MARKETING_WALLET,
            VESTING_WALLET,
            DAO_CONTRACT
        );
        console.log("Presale Contract deployed at: ", address(presaleContract));

        // 4. Set NFT Collection's presale contract address
        console.log("Setting contract addresses in NFT Collection...");
        nftCollection.setContractAddresses(
            address(presaleContract),
            DAO_CONTRACT
        );

        // 5. Setup rarity URIs in NFT Collection
        console.log("Setting up rarity URIs in NFT Collection...");
        nftCollection.setRarityURI(MRTCollection.Rarity.COMMON, "ipfs://bafybeid2236qukuqfxd5763l6jnuipsgdg4acano4ez7wbl47rutn54ify/Common.json");
        nftCollection.setRarityURI(MRTCollection.Rarity.UNCOMMON, "ipfs://bafybeid2236qukuqfxd5763l6jnuipsgdg4acano4ez7wbl47rutn54ify/Uncommon.json");
        nftCollection.setRarityURI(MRTCollection.Rarity.RARE, "ipfs://bafybeid2236qukuqfxd5763l6jnuipsgdg4acano4ez7wbl47rutn54ify/Rare.json");
        nftCollection.setRarityURI(MRTCollection.Rarity.EPIC, "ipfs://bafybeid2236qukuqfxd5763l6jnuipsgdg4acano4ez7wbl47rutn54ify/Epic.json");
        nftCollection.setRarityURI(MRTCollection.Rarity.LEGENDARY, "ipfs://bafybeid2236qukuqfxd5763l6jnuipsgdg4acano4ez7wbl47rutn54ify/Legendary.json");

        // 6. Create a public presale
        console.log("Creating public presale...");
        uint256 presaleId = presaleContract.createPresale(
            block.timestamp + 100,
            block.timestamp + 10000000,
            MAX_SUPPLY,
            BASE_PRICE,
            MRT_BASE_PRICE,
            0, // USDT price set to 0 as we're not using USDT
            PRICE_INCREASE_RATE,
            MRT_PRICE_INCREASE_RATE,
            0, // USDT price increase rate set to 0
            bytes32(0), // No merkle root needed for public sale
            MAX_PER_ADDRESS,
            false // Public sale
        );
        console.log("Created presale with ID: ", presaleId);

        console.log("Deployment completed successfully!");
        vm.stopBroadcast();
    }
}