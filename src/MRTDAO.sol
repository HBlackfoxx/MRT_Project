// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IMRTCollection {
    enum Rarity { COMMON, UNCOMMON, RARE, EPIC, LEGENDARY }
    function tokenRarity(uint256 tokenId) external view returns (Rarity);
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
}

/**
 * @title MRTDAO
 * @dev DAO governance contract for MRT ecosystem
 */
contract MRTDAO is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    
    // NFT Collection contract
    IMRTCollection public nftCollection;
    
    // MRT token
    IERC20 public mrtToken;
    
    // Proposal struct
    struct Proposal {
        uint256 id;
        string title;
        string description;
        uint256 startTime;
        uint256 endTime;
        address proposer;
        bool executed;
        bytes callData;
        address targetContract;
        uint256 forVotes;
        uint256 againstVotes;
        mapping(address => bool) hasVoted;
        mapping(address => uint256) votingPower;
        mapping(address => bool) voteDirection; // true = for, false = against
    }
    
    // Proposal mapping and counter
    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    
    // Voting parameters
    uint256 public votingPeriod = 7 days;
    uint256 public executionDelay = 2 days;
    uint256 public minProposalThreshold = 100 * 10**18; // 100 MRT tokens
    
    // Voting power tiers for NFTs based on rarity
    mapping(IMRTCollection.Rarity => uint256) public nftVotingPower;
    
    // Community fund
    uint256 public communityFund;
    
    // Events
    event ProposalCreated(uint256 indexed proposalId, string title, address proposer);
    event Voted(uint256 indexed proposalId, address voter, bool support, uint256 votingPower);
    event ProposalExecuted(uint256 indexed proposalId);
    event FundsAdded(uint256 amount);
    event FundsWithdrawn(address recipient, uint256 amount);
    event VotingParametersUpdated(uint256 votingPeriod, uint256 executionDelay, uint256 minProposalThreshold);
    event NFTVotingPowerUpdated(uint256[] votingPowers);
    
    /**
     * @dev Constructor
     * @param nftCollectionAddress The address of the NFT collection contract
     * @param mrtTokenAddress The address of the MRT token contract
     */
    constructor(
        address nftCollectionAddress,
        address mrtTokenAddress
    ) Ownable(msg.sender) {
        nftCollection = IMRTCollection(nftCollectionAddress);
        mrtToken = IERC20(mrtTokenAddress);
        
        // Set initial voting power for NFTs based on rarity
        nftVotingPower[IMRTCollection.Rarity.COMMON] = 1;
        nftVotingPower[IMRTCollection.Rarity.UNCOMMON] = 2;
        nftVotingPower[IMRTCollection.Rarity.RARE] = 5;
        nftVotingPower[IMRTCollection.Rarity.EPIC] = 10;
        nftVotingPower[IMRTCollection.Rarity.LEGENDARY] = 25;
    }
    
    /**
     * @dev Update voting parameters
     * @param _votingPeriod New voting period in seconds
     * @param _executionDelay New execution delay in seconds
     * @param _minProposalThreshold New minimum proposal threshold
     */
    function updateVotingParameters(
        uint256 _votingPeriod,
        uint256 _executionDelay,
        uint256 _minProposalThreshold
    ) external onlyOwner {
        votingPeriod = _votingPeriod;
        executionDelay = _executionDelay;
        minProposalThreshold = _minProposalThreshold;
        
        emit VotingParametersUpdated(_votingPeriod, _executionDelay, _minProposalThreshold);
    }
    
    /**
     * @dev Update NFT voting power tiers
     * @param votingPowers Array of voting powers [COMMON, UNCOMMON, RARE, EPIC, LEGENDARY]
     */
    function updateNFTVotingPower(uint256[] calldata votingPowers) external onlyOwner {
        require(votingPowers.length == 5, "Invalid array length");
        
        nftVotingPower[IMRTCollection.Rarity.COMMON] = votingPowers[0];
        nftVotingPower[IMRTCollection.Rarity.UNCOMMON] = votingPowers[1];
        nftVotingPower[IMRTCollection.Rarity.RARE] = votingPowers[2];
        nftVotingPower[IMRTCollection.Rarity.EPIC] = votingPowers[3];
        nftVotingPower[IMRTCollection.Rarity.LEGENDARY] = votingPowers[4];
        
        emit NFTVotingPowerUpdated(votingPowers);
    }
    
    /**
     * @dev Add funds to community treasury
     */
    function addFunds() external payable {
        communityFund = communityFund.add(msg.value);
        emit FundsAdded(msg.value);
    }
    
    /**
     * @dev Add ERC20 tokens to community treasury
     * @param amount Amount of MRT tokens to add
     */
    function addTokenFunds(uint256 amount) external {
        require(mrtToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");
        emit FundsAdded(amount);
    }
    
    /**
     * @dev Calculate the voting power of an address
     * @param voter The address to calculate voting power for
     * @return The total voting power
     */
    function calculateVotingPower(address voter) public view returns (uint256) {
        // Voting power from MRT tokens
        uint256 tokenVotingPower = mrtToken.balanceOf(voter).div(10**18); // 1 token = 1 vote
        
        // Voting power from NFTs
        uint256 nftCount = nftCollection.balanceOf(voter);
        uint256 nftVotingPowerTotal = 0;
        
        for (uint256 i = 0; i < nftCount; i++) {
            uint256 tokenId = nftCollection.tokenOfOwnerByIndex(voter, i);
            IMRTCollection.Rarity rarity = nftCollection.tokenRarity(tokenId);
            nftVotingPowerTotal = nftVotingPowerTotal.add(nftVotingPower[rarity]);
        }
        
        return tokenVotingPower.add(nftVotingPowerTotal);
    }
    
    /**
     * @dev Create a new proposal
     * @param title Proposal title
     * @param description Proposal description
     * @param targetContract Contract to call if proposal passes
     * @param callData Function call data for execution
     */
    function createProposal(
        string memory title,
        string memory description,
        address targetContract,
        bytes memory callData
    ) external nonReentrant {
        uint256 votingPower = calculateVotingPower(msg.sender);
        require(votingPower >= minProposalThreshold, "Insufficient voting power to create proposal");
        
        uint256 proposalId = proposalCount++;
        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.title = title;
        proposal.description = description;
        proposal.startTime = block.timestamp;
        proposal.endTime = block.timestamp.add(votingPeriod);
        proposal.proposer = msg.sender;
        proposal.executed = false;
        proposal.callData = callData;
        proposal.targetContract = targetContract;
        
        emit ProposalCreated(proposalId, title, msg.sender);
    }
    
    /**
     * @dev Cast vote on a proposal
     * @param proposalId The ID of the proposal
     * @param support Whether to vote for or against the proposal
     */
    function castVote(uint256 proposalId, bool support) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        
        require(block.timestamp >= proposal.startTime, "Voting has not started");
        require(block.timestamp <= proposal.endTime, "Voting has ended");
        require(!proposal.executed, "Proposal already executed");
        require(!proposal.hasVoted[msg.sender], "Already voted");
        
        uint256 votingPower = calculateVotingPower(msg.sender);
        require(votingPower > 0, "No voting power");
        
        proposal.hasVoted[msg.sender] = true;
        proposal.votingPower[msg.sender] = votingPower;
        proposal.voteDirection[msg.sender] = support;
        
        if (support) {
            proposal.forVotes = proposal.forVotes.add(votingPower);
        } else {
            proposal.againstVotes = proposal.againstVotes.add(votingPower);
        }
        
        emit Voted(proposalId, msg.sender, support, votingPower);
    }
    
    /**
     * @dev Execute a successful proposal
     * @param proposalId The ID of the proposal to execute
     */
    function executeProposal(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        
        require(block.timestamp > proposal.endTime, "Voting still in progress");
        require(block.timestamp <= proposal.endTime.add(executionDelay), "Execution window passed");
        require(!proposal.executed, "Proposal already executed");
        require(proposal.forVotes > proposal.againstVotes, "Proposal did not pass");
        
        proposal.executed = true;
        
        // Execute the proposal
        (bool success, ) = proposal.targetContract.call(proposal.callData);
        require(success, "Proposal execution failed");
        
        emit ProposalExecuted(proposalId);
    }
    
    /**
     * @dev Withdraw funds from community treasury (requires DAO proposal)
     * @param recipient Recipient of the funds
     * @param amount Amount to withdraw
     */
    function withdrawFunds(address payable recipient, uint256 amount) external {
        // This function would typically be restricted to be called through a proposal
        // For simplicity, we're allowing owner access here
        require(msg.sender == owner(), "Only callable through proposal execution");
        require(amount <= communityFund, "Insufficient funds");
        
        communityFund = communityFund.sub(amount);
        recipient.transfer(amount);
        
        emit FundsWithdrawn(recipient, amount);
    }
    
    /**
     * @dev Withdraw ERC20 tokens from treasury (requires DAO proposal)
     * @param recipient Recipient of the tokens
     * @param amount Amount to withdraw
     */
    function withdrawTokens(address recipient, uint256 amount) external {
        // This function would typically be restricted to be called through a proposal
        // For simplicity, we're allowing owner access here
        require(msg.sender == owner(), "Only callable through proposal execution");
        require(mrtToken.transfer(recipient, amount), "Token transfer failed");
        
        emit FundsWithdrawn(recipient, amount);
    }
    
    /**
     * @dev Get proposal details
     * @param proposalId The ID of the proposal
     * @return title, description, startTime, endTime, proposer, executed, forVotes, againstVotes
     */
    function getProposalDetails(uint256 proposalId) external view returns (
        string memory title,
        string memory description,
        uint256 startTime,
        uint256 endTime,
        address proposer,
        bool executed,
        uint256 forVotes,
        uint256 againstVotes
    ) {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.title,
            proposal.description,
            proposal.startTime,
            proposal.endTime,
            proposal.proposer,
            proposal.executed,
            proposal.forVotes,
            proposal.againstVotes
        );
    }
    
    /**
     * @dev Check if an address has voted on a proposal
     * @param proposalId The ID of the proposal
     * @param voter The address to check
     * @return Whether the address has voted and their voting direction
     */
    function hasVoted(uint256 proposalId, address voter) external view returns (bool, bool) {
        Proposal storage proposal = proposals[proposalId];
        return (proposal.hasVoted[voter], proposal.voteDirection[voter]);
    }
    
    /**
     * @dev Receive function to accept ETH payments
     */
    receive() external payable {
        communityFund = communityFund.add(msg.value);
        emit FundsAdded(msg.value);
    }
}