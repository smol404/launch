pragma solidity ^0.8.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/token/ERC721/ERC721Upgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/security/ReentrancyGuardUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/access/OwnableUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/proxy/utils/UUPSUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/utils/CountersUpgradeable.sol";
import "interfaces/IbortBAP578.sol";
import "interfaces/ICircuitBreaker.sol";
import "interfaces/IAgentController.sol";

/**
 * @title BAP578 - BORT Token Standard
 * @dev Implementation of the BAP-578 standard for autonomous agent tokens
 */
contract BAP578 is
    IBAP578,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    ERC721URIStorageUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using CountersUpgradeable for CountersUpgradeable.Counter;

    // Token ID counter
    CountersUpgradeable.Counter private _tokenIdCounter;

    // Mapping from token ID to agent state
    mapping(uint256 => State) private _agentStates;

    // Mapping from token ID to extended agent metadata
    mapping(uint256 => AgentMetadata) private _agentExtendedMetadata;

    ICircuitBreaker public circuitBreaker;

    address public minter;
    address public controller;
    uint256 public seizedBalance;
    address public treasury;

    modifier onlyMinter() {
        require(msg.sender == minter, "not minter");
        _;
    }

    /**
     * @dev Modifier to check if the caller is the owner of the token
     */
    modifier onlyAgentOwner(uint256 tokenId) {
        require(ownerOf(tokenId) == msg.sender, "BAP578: caller is not agent owner");
        _;
    }

    /**
     * @dev Modifier to check if the agent is active
     */
    modifier whenAgentActive(uint256 tokenId) {
        require(!ICircuitBreaker(circuitBreaker).globalPause(), "BAP578: global pause active");
        require(_agentStates[tokenId].status == Status.Active, "BAP578: agent not active");
        _;
    }

    /**
     * @dev Initializes the contract
     * @dev This function can only be called once due to the initializer modifier
     */
    function initialize(
        string memory name,
        string memory symbol,
        address circuitBreakerAddress,
        address _treasury,
        address owner_
    ) public initializer {
        __ERC721_init(name, symbol);
        __ERC721Enumerable_init();
        __ERC721URIStorage_init();
        __ReentrancyGuard_init();
        __Ownable_init();
        __UUPSUpgradeable_init();

        circuitBreaker = ICircuitBreaker(circuitBreakerAddress);
        treasury = _treasury;

        _transferOwnership(owner_);
}

    /**
     * @dev Creates a new agent token with extended metadata
     * @param to The address that will own the agent
     * @param logicAddress The address of the logic contract
     * @param metadataURI The URI for the agent's metadata
     * @param extendedMetadata The extended metadata for the agent
     * @return tokenId The ID of the new agent token
     */
    function createAgent(
        address to,
        address logicAddress,
        string memory metadataURI,
        AgentMetadata memory extendedMetadata
    ) external onlyMinter nonReentrant returns (uint256 tokenId) {
        return _createAgent(to, logicAddress, metadataURI, extendedMetadata);
    }

    /**
     * @dev Creates a new agent token with basic metadata
     * @param to The address that will own the agent
     * @param logicAddress The address of the logic contract
     * @param metadataURI The URI for the agent's metadata
     * @return tokenId The ID of the new agent token
     */
    function createAgent(
        address to,
        address logicAddress,
        string memory metadataURI
    ) external onlyMinter nonReentrant returns (uint256 tokenId) {
        AgentMetadata memory emptyMetadata = AgentMetadata({
            persona: "",
            experience: "",
            voiceHash: "",
            animationURI: "",
            vaultURI: "",
            vaultHash: bytes32(0)
        });

        return _createAgent(to, logicAddress, metadataURI, emptyMetadata);
    }

    function _createAgent(
        address to,
        address logicAddress,
        string memory metadataURI,
        AgentMetadata memory extendedMetadata
    ) internal returns (uint256 tokenId) {
        require(to != address(0), "BAP578: zero to");
        require(logicAddress != address(0), "BAP578: logic address is zero");

        _tokenIdCounter.increment();
        tokenId = _tokenIdCounter.current();

        _safeMint(to, tokenId);
        _setTokenURI(tokenId, metadataURI);

        _agentStates[tokenId] = State({
            balance: 0,
            status: Status.Active,
            owner: to,
            logicAddress: logicAddress,
            lastActionTimestamp: block.timestamp
        });

        _agentExtendedMetadata[tokenId] = extendedMetadata;

        return tokenId;
    }

    /**
     * @dev Updates the logic address for the agent
     * @param tokenId The ID of the agent token
     * @param newLogic The address of the new logic contract
     */
    function setLogicAddress(uint256 tokenId, address newLogic) external onlyAgentOwner(tokenId) {
        require(newLogic != address(0), "BAP578: new logic address is zero");

        address oldLogic = _agentStates[tokenId].logicAddress;
        _agentStates[tokenId].logicAddress = newLogic;

        emit LogicUpgraded(address(this), oldLogic, newLogic);
    }

    /**
     * @dev Funds the agent with BNB for gas fees
     * @param tokenId The ID of the agent token
     */
    function fundAgent(uint256 tokenId) external payable {
        require(_exists(tokenId), "BAP578: agent does not exist");

        _agentStates[tokenId].balance += msg.value;

        emit AgentFunded(address(this), msg.sender, msg.value);
    }

    /**
     * @dev Returns the current state of the agent
     * @param tokenId The ID of the agent token
     * @return The agent's state
     */
    function getState(uint256 tokenId) external view returns (State memory) {
        require(_exists(tokenId), "BAP578: agent does not exist");
        return _agentStates[tokenId];
    }

    /**
     * @dev Gets the agent's extended metadata
     * @param tokenId The ID of the agent token
     * @return The agent's extended metadata
     */
    function getAgentMetadata(uint256 tokenId) external view returns (AgentMetadata memory) {
        require(_exists(tokenId), "BAP578: agent does not exist");
        return _agentExtendedMetadata[tokenId];
    }

    /**
     * @dev Pauses the agent
     * @param tokenId The ID of the agent token
     */
    function pause(uint256 tokenId) external onlyAgentOwner(tokenId) {
        require(_agentStates[tokenId].status == Status.Active, "BAP578: agent not active");

        _agentStates[tokenId].status = Status.Paused;

        emit StatusChanged(address(this), Status.Paused);
    }

    /**
     * @dev Resumes the agent
     * @param tokenId The ID of the agent token
     */
    function unpause(uint256 tokenId) external onlyAgentOwner(tokenId) {
        require(_agentStates[tokenId].status == Status.Paused, "BAP578: agent not paused");

        _agentStates[tokenId].status = Status.Active;

        emit StatusChanged(address(this), Status.Active);
    }

    /**
     * @dev Terminates the agent permanently
     * @param tokenId The ID of the agent token
     */

    function burnAgent(uint256 tokenId) external {
        require(msg.sender == minter);
        uint256 bal = _agentStates[tokenId].balance;
        if (bal > 0) {
            _agentStates[tokenId].balance = 0;
            seizedBalance += bal;
        }
        _agentStates[tokenId].status = Status.Terminated;
        _agentStates[tokenId].owner = address(0);
        _agentStates[tokenId].logicAddress = address(0); 
        _agentStates[tokenId].lastActionTimestamp = block.timestamp;       
        _burn(tokenId);
    }

    function withdrawSeized(uint256 amount) external {
        require(msg.sender == treasury, "treasury only");
        require(amount <= seizedBalance, "too much");
        seizedBalance -= amount;
        (bool ok,) = payable(treasury).call{value: amount}("");
        require(ok, "pay fail");
    }

    /**
     * @dev Withdraws BNB from the agent
     * @param tokenId The ID of the agent token
     * @param amount The amount to withdraw
     */
    function withdrawFromAgent(uint256 tokenId, uint256 amount) external onlyAgentOwner(tokenId) {
        require(amount <= _agentStates[tokenId].balance, "BAP578: insufficient balance");

        _agentStates[tokenId].balance -= amount;
        (bool ok,) = payable(ownerOf(tokenId)).call{value: amount}("");
        require(ok, "refund failed");
    }

    /**
     * @dev See {IERC165-supportsInterface}
     */
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable, ERC721URIStorageUpgradeable)
        returns (bool)
    {
        return interfaceId == type(IBAP578).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev See {ERC721-_beforeTokenTransfer}
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal override(ERC721Upgradeable, ERC721EnumerableUpgradeable) {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);

        // Update owner in agent state when transferred
        if (from != address(0) && to != address(0)) {
            require(controller != address(0), "no controller");
            IAgentController(controller).onAgentTransfer(from, to, tokenId);
            _agentStates[tokenId].owner = to;
        }
    }

    /**
     * @dev See {ERC721URIStorage-_burn}
     */
    function _burn(
        uint256 tokenId
    ) internal override(ERC721Upgradeable, ERC721URIStorageUpgradeable) {
        super._burn(tokenId);
    }

    /**
     * @dev See {ERC721URIStorage-tokenURI}
     */
    function tokenURI(
        uint256 tokenId
    ) public view override(ERC721Upgradeable, ERC721URIStorageUpgradeable) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    /**
     * @dev Upgrades the contract to a new implementation and calls a function on the new implementation.
     * Inherits the implementation from UUPSUpgradeable parent contract.
     * The _authorizeUpgrade function below controls access to this function.
     */
    // Function is inherited from UUPSUpgradeable and doesn't need to be re-implemented

    /**
     * @dev Upgrades the contract to a new implementation.
     * Inherits the implementation from UUPSUpgradeable parent contract.
     * The _authorizeUpgrade function below controls access to this function.
     */
    // Function is inherited from UUPSUpgradeable and doesn't need to be re-implemented

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract.
     * Called by {upgradeTo} and {upgradeToAndCall}.
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setMinter(address _address) external onlyOwner {
        require(_address != address(0));
        minter = _address;
    }

    function setController(address _address) external onlyOwner {
        require(_address != address(0));
        controller = _address;
    }

    receive() external payable {}
}
