pragma solidity ^0.8.9;


contract TradingAgentLogicV4 {
    // ── PancakeSwap V2 Router on BSC Mainnet ──
    IPancakeRouter02 public constant ROUTER =
        IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    // ── WBNB on BSC Mainnet ──
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // ── FourMeme Bonding Curve Contracts on BSC Mainnet ──
    

    string public name = "TradingAgentLogicV4";
    string public version = "4.0.0-multibap";

    // ── Per-agent balances keyed by (bap, tokenId) ──
    mapping(address => mapping(uint256 => uint256)) public agentBNBBalance;
    mapping(address => mapping(uint256 => mapping(address => uint256))) public agentTokenBalance;

    // ── Authorized callers (runtime signers) ──
    mapping(address => bool) public authorizedCallers;
    address public owner;
    address public pendingOwner;

    // ── Pausable ──
    bool public paused;

    // ── Reentrancy guard ──
    uint256 private _reentrancyStatus;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ── Slippage config (basis points) ──
    uint256 public defaultSlippageBps = 500; // 5%
    uint256 public constant MAX_SLIPPAGE_BPS = 4000; // 40%
    uint256 public constant DEADLINE_EXTENSION = 300;

    // ── Gas reimbursement ──
    bool public gasReimbursementEnabled = true;
    uint256 public gasOverhead = 50000;

    // ── Events ──
    event ActionHandled(address indexed bap, uint256 indexed tokenId, string action, bool success, bytes result);
    event TradingActionRequested(
        address indexed bap,
        uint256 indexed tokenId,
        address indexed caller,
        string action,
        address tokenAddress,
        uint256 amount,
        uint256 slippageBps
    );
    event SwapExecuted(
        address indexed bap,
        uint256 indexed tokenId,
        string swapType,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event Deposited(address indexed bap, uint256 indexed tokenId, address token, uint256 amount);
    event Withdrawn(address indexed bap, uint256 indexed tokenId, address token, uint256 amount, address to);

    event CallerAuthorized(address caller);
    event CallerRevoked(address caller);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address account);
    event Unpaused(address account);
    event SlippageUpdated(uint256 oldBps, uint256 newBps);
    event EmergencyWithdraw(address token, uint256 amount, address to);

    event AgentOwnerWithdraw(address indexed bap, uint256 indexed tokenId, address indexed agentOwner, address token, uint256 amount);
    event GasReimbursed(address indexed bap, uint256 indexed tokenId, address indexed caller, uint256 gasUsed, uint256 gasCost);


    // ── Errors ──
    error NotOwner();
    error NotAuthorized();
    error PausedErr();
    error Reentrancy();
    error ZeroAddress();
    error AgentNotActive();
    error NotAgentOwner();
    error Insufficient();
    error TransferFailed();

    // ── Modifiers ──
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAuthorized() {
        if (!(authorizedCallers[msg.sender] || msg.sender == owner)) revert NotAuthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedErr();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert Reentrancy();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }


    modifier validBap(address bap) {
        require(bap != address(0) && bap.code.length > 0, "bap invalid");
        _;
    }

    modifier onlyAgentOwner(address bap, uint256 tokenId) {
        if (IERC721Ownable(bap).ownerOf(tokenId) != msg.sender) revert NotAgentOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
        authorizedCallers[msg.sender] = true;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ── Admin: callers / config ──
    function authorizeCaller(address caller) external onlyOwner {
        if (caller == address(0)) revert ZeroAddress();
        authorizedCallers[caller] = true;
        emit CallerAuthorized(caller);
    }

    function revokeCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = false;
        emit CallerRevoked(caller);
    }

    function setDefaultSlippage(uint256 bps) external onlyOwner {
        require(bps <= MAX_SLIPPAGE_BPS, "Slippage too high");
        emit SlippageUpdated(defaultSlippageBps, bps);
        defaultSlippageBps = bps;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setGasReimbursementEnabled(bool _enabled) external onlyOwner {
        gasReimbursementEnabled = _enabled;
    }

    function setGasOverhead(uint256 _overhead) external onlyOwner {
        gasOverhead = _overhead;
    }

    // ── Deposit / Withdraw (now requires bap) ──
    function depositBNB(address bap, uint256 tokenId)
        external
        payable
        validBap(bap)
        whenNotPaused
    {
       
        require(msg.value > 0, "No BNB sent");
        // Existence check (ownerOf reverts if not minted)
        IERC721Ownable(bap).ownerOf(tokenId);
         _assertLogicMatch(bap, tokenId);

        agentBNBBalance[bap][tokenId] += msg.value;
        emit Deposited(bap, tokenId, address(0), msg.value);
    }

    function depositToken(address bap, uint256 tokenId, address token, uint256 amount)
        external
        validBap(bap)
        whenNotPaused
        nonReentrant
    {
        
        require(amount > 0, "Zero amount");
        require(token != address(0), "Zero token address");

        IERC721Ownable(bap).ownerOf(tokenId);
        _assertLogicMatch(bap, tokenId);

        uint256 balBefore = IERC20(token).balanceOf(address(this));
        _safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        require(received > 0, "Zero tokens received");

        agentTokenBalance[bap][tokenId][token] += received;
        emit Deposited(bap, tokenId, token, received);
    }

    // Admin withdrawals (global admin)
    function withdrawBNB(address bap, uint256 tokenId, uint256 amount, address payable to)
        external
        onlyOwner
        nonReentrant
    {
        _assertLogicMatch(bap, tokenId);
        require(to != address(0), "Zero address");
        require(agentBNBBalance[bap][tokenId] >= amount, "Insufficient BNB");
        agentBNBBalance[bap][tokenId] -= amount;
        (bool sent,) = to.call{value: amount}("");
        require(sent, "BNB transfer failed");
        emit Withdrawn(bap, tokenId, address(0), amount, to);
    }

    function withdrawToken(address bap, uint256 tokenId, address token, uint256 amount, address to)
        external
        onlyOwner
        nonReentrant
    {
        _assertLogicMatch(bap, tokenId);
        require(to != address(0), "Zero address");
        require(agentTokenBalance[bap][tokenId][token] >= amount, "Insufficient balance");
        agentTokenBalance[bap][tokenId][token] -= amount;
        _safeTransfer(token, to, amount);
        emit Withdrawn(bap, tokenId, token, amount, to);
    }

    // NFT owner withdrawals (per-agent owner, optional in keeper model)
    function agentOwnerWithdrawBNB(address bap, uint256 tokenId, uint256 amount)
        external
        validBap(bap)
        whenNotPaused
        nonReentrant
        onlyAgentOwner(bap, tokenId)
    {
        _assertLogicMatch(bap, tokenId);
        require(amount > 0, "Zero amount");
        require(agentBNBBalance[bap][tokenId] >= amount, "Insufficient BNB");

        agentBNBBalance[bap][tokenId] -= amount;

        (bool sent,) = payable(msg.sender).call{value: amount}("");
        require(sent, "BNB transfer failed");

        emit AgentOwnerWithdraw(bap, tokenId, msg.sender, address(0), amount);
    }

    function agentOwnerWithdrawToken(address bap, uint256 tokenId, address token, uint256 amount)
        external
        validBap(bap)
        whenNotPaused
        nonReentrant
        onlyAgentOwner(bap, tokenId)
    {
        _assertLogicMatch(bap, tokenId);
        require(amount > 0, "Zero amount");
        require(token != address(0), "Zero token address");
        require(agentTokenBalance[bap][tokenId][token] >= amount, "Insufficient balance");

        agentTokenBalance[bap][tokenId][token] -= amount;
        _safeTransfer(token, msg.sender, amount);

        emit AgentOwnerWithdraw(bap, tokenId, msg.sender, token, amount);
    }

    // Emergency (same as before, but "tracked" is now expensive to compute)
    function emergencyWithdrawBNB(address payable to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Zero address");
        require(amount <= address(this).balance, "Too much");
        (bool sent,) = to.call{value: amount}("");
        require(sent, "BNB transfer failed");
        emit EmergencyWithdraw(address(0), amount, to);
    }

    function emergencyWithdrawToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Zero address");
        _safeTransfer(token, to, amount);
        emit EmergencyWithdraw(token, amount, to);
    }

    // ── Main action handler (now requires bap) ──
    function handleAction(
        address bap,
        uint256 tokenId,
        string calldata action,
        bytes calldata payload
    )
        external
        onlyAuthorized
        whenNotPaused
        nonReentrant
        returns (bool success, bytes memory result)
    {
        
        (uint8 _st, address _logicAddr) = _getState(bap, tokenId);
        require(_st == 1, "agent inactive");
        require(_logicAddr == address(this), "logic mismatch");
        
        uint256 gasStart = gasleft();
        bytes32 actionHash = keccak256(bytes(action));

        if (actionHash == keccak256(bytes("buy_token"))) {
            (success, result) = _handleBuyToken(bap, tokenId, payload);
        } else if (actionHash == keccak256(bytes("sell_token"))) {
            (success, result) = _handleSellToken(bap, tokenId, payload);
        } else if (actionHash == keccak256(bytes("check_balance"))) {
            (success, result) = _handleCheckBalance(bap, tokenId, payload);
        } else if (actionHash == keccak256(bytes("get_price"))) {
            (success, result) = _handleGetPrice(payload);
        } else {
            emit ActionHandled(bap, tokenId, action, false, abi.encode("Unknown action"));
            (success, result) = (false, abi.encode("Unknown action"));
        }

        _reimburseGas(bap, tokenId, gasStart);
        return (success, result);
    }

    // ── Gas reimbursement (keyed by bap, tokenId) ──
    function _reimburseGas(address bap, uint256 tokenId, uint256 gasStart) internal {
        if (!gasReimbursementEnabled) return;

        uint256 gasUsed = gasStart - gasleft() + gasOverhead;
        uint256 gasCost = gasUsed * tx.gasprice;

        // If you want "trade still succeeds", do NOT revert here. Early return instead.
        if (agentBNBBalance[bap][tokenId] < gasCost) return;

        agentBNBBalance[bap][tokenId] -= gasCost;
        (bool sent,) = msg.sender.call{value: gasCost}("");
        if (sent) {
            emit GasReimbursed(bap, tokenId, msg.sender, gasUsed, gasCost);
        } else {
            agentBNBBalance[bap][tokenId] += gasCost;
        }
    }

    // ── Handlers (now take bap) ──
    function _handleBuyToken(address bap, uint256 tokenId, bytes calldata payload)
        internal
        returns (bool, bytes memory)
    {
        (address tokenAddress, uint256 amountBNB, uint256 slippageBps) =
            abi.decode(payload, (address, uint256, uint256));

        require(tokenAddress != address(0), "Zero token address");
        if (slippageBps == 0) slippageBps = defaultSlippageBps;
        require(slippageBps <= MAX_SLIPPAGE_BPS, "Slippage too high");
        require(agentBNBBalance[bap][tokenId] >= amountBNB, "Insufficient BNB balance");

        emit TradingActionRequested(bap, tokenId, msg.sender, "buy_token", tokenAddress, amountBNB, slippageBps);
        agentBNBBalance[bap][tokenId] -= amountBNB;

        uint256 tokensReceived = _swapBNBForToken(tokenAddress, amountBNB, slippageBps);
        agentTokenBalance[bap][tokenId][tokenAddress] += tokensReceived;

        emit SwapExecuted(bap, tokenId, "buy", WBNB, tokenAddress, amountBNB, tokensReceived);
        emit ActionHandled(bap, tokenId, "buy_token", true, abi.encode("Trade executed successfully"));
        return (true, abi.encode("Trade executed successfully"));
    }

    function _handleSellToken(address bap, uint256 tokenId, bytes calldata payload)
        internal
        returns (bool, bytes memory)
    {
        (address tokenAddress, uint256 amountTokens, uint256 slippageBps) =
            abi.decode(payload, (address, uint256, uint256));

        require(tokenAddress != address(0), "Zero token address");
        if (slippageBps == 0) slippageBps = defaultSlippageBps;
        require(slippageBps <= MAX_SLIPPAGE_BPS, "Slippage too high");
        require(agentTokenBalance[bap][tokenId][tokenAddress] >= amountTokens, "Insufficient token balance");

        emit TradingActionRequested(bap, tokenId, msg.sender, "sell_token", tokenAddress, amountTokens, slippageBps);
        agentTokenBalance[bap][tokenId][tokenAddress] -= amountTokens;

        uint256 bnbReceived = _swapTokenForBNB(tokenAddress, amountTokens, slippageBps);
        agentBNBBalance[bap][tokenId] += bnbReceived;

        emit SwapExecuted(bap, tokenId, "sell", tokenAddress, WBNB, amountTokens, bnbReceived);
        emit ActionHandled(bap, tokenId, "sell_token", true, abi.encode("Trade executed successfully"));
        return (true, abi.encode("Trade executed successfully"));
    }

    function _handleCheckBalance(address bap, uint256 tokenId, bytes calldata payload)
        internal
        returns (bool, bytes memory)
    {
        address tokenAddress = abi.decode(payload, (address));
        uint256 tokenBal = agentTokenBalance[bap][tokenId][tokenAddress];
        uint256 bnbBal = agentBNBBalance[bap][tokenId];
        emit ActionHandled(bap, tokenId, "check_balance", true, abi.encode(bnbBal, tokenBal));
        return (true, abi.encode(bnbBal, tokenBal));
    }

    function _handleGetPrice(
        bytes calldata payload
    ) internal view returns (bool, bytes memory) {
        (address tokenAddress, uint256 amountIn, bool isBuyQuote) =
            abi.decode(payload, (address, uint256, bool));

        address[] memory path = new address[](2);
        if (isBuyQuote) {
            path[0] = WBNB;
            path[1] = tokenAddress;
        } else {
            path[0] = tokenAddress;
            path[1] = WBNB;
        }

        uint[] memory amounts = ROUTER.getAmountsOut(amountIn, path);
        return (true, abi.encode(amounts[1]));
    }

    

    // ── Swaps ──
    function _swapBNBForToken(address tokenAddress, uint256 amountBNB, uint256 slippageBps) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = tokenAddress;

        uint256 minOut = _getMinOut(amountBNB, path, slippageBps);

        uint256 balBefore = IERC20(tokenAddress).balanceOf(address(this));

        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountBNB}(
            minOut, path, address(this), block.timestamp + DEADLINE_EXTENSION
        );

        uint256 received = IERC20(tokenAddress).balanceOf(address(this)) - balBefore;
        require(received > 0, "Swap returned zero tokens");
        return received;
    }

    function _swapTokenForBNB(address tokenAddress, uint256 amountTokens, uint256 slippageBps) internal returns (uint256) {
        _safeApprove(tokenAddress, address(ROUTER), 0);
        _safeApprove(tokenAddress, address(ROUTER), amountTokens);

        address[] memory path = new address[](2);
        path[0] = tokenAddress;
        path[1] = WBNB;

        uint256 minOut = _getMinOut(amountTokens, path, slippageBps);

        uint256 balBefore = address(this).balance;

        ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountTokens, minOut, path, address(this), block.timestamp + DEADLINE_EXTENSION
        );

        uint256 received = address(this).balance - balBefore;
        require(received > 0, "Swap returned zero BNB");
        return received;
    }

    function _getMinOut(uint256 amountIn, address[] memory path, uint256 slippageBps) internal view returns (uint256) {
        uint[] memory expected = ROUTER.getAmountsOut(amountIn, path);
        return (expected[1] * (10000 - slippageBps)) / 10000;
    }

    receive() external payable {}

    // ── SafeERC20 helpers ──
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transfer failed");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transferFrom failed");
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.approve.selector, spender, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: approve failed");
    }

    function _assertLogicMatch(address bap, uint256 tokenId) internal view {
        require(bap != address(0) && bap.code.length > 0, "bap invalid");
        (, , , address logicAddr, ) = IBAP578State(bap).getState(tokenId);
            require(logicAddr == address(this), "logic mismatch");
    }

    function _getState(address bap, uint256 tokenId) internal view returns (uint8 st, address logicAddr) {
        (, uint8 _st, , address _logic, ) = IBAP578State(bap).getState(tokenId);
        return (_st, _logic);
    }
}

