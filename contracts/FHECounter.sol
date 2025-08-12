// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool, euint256, externalEuint32, externalEuint256 } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FHE-secured Lending and Borrowing Platform
contract FHELendingPlatform is SepoliaConfig {
    // Token information structure
    struct TokenInfo {
        address tokenAddress;
        euint256 totalLiquidity;
        euint256 totalBorrowed;
        euint256 interestRate; // Annual percentage rate (APR) in basis points (1% = 100)
        bool isActive;
    }

    // User position structure
    struct UserPosition {
        euint256 suppliedAmount;
        euint256 borrowedAmount;
        euint256 collateralValue;
    }

    // Contract owner
    address public owner;

    // Supported tokens mapping
    mapping(address => TokenInfo) public supportedTokens;
    address[] public tokenList;

    // User positions mapping
    mapping(address => mapping(address => UserPosition)) public userPositions;

    // Loan-to-Value ratio (60% = 6000 basis points)
    euint32 private constant LTV_RATIO = FHE.asEuint32(6000);

    // Liquidation threshold (80% = 8000 basis points)
    euint32 private constant LIQUIDATION_THRESHOLD = FHE.asEuint32(8000);

    // Events
    event TokenAdded(address indexed tokenAddress);
    event TokenRemoved(address indexed tokenAddress);
    event Deposit(address indexed user, address indexed token, euint256 amount);
    event Withdraw(address indexed user, address indexed token, euint256 amount);
    event Borrow(address indexed user, address indexed token, euint256 amount);
    event Repay(address indexed user, address indexed token, euint256 amount);
    event Liquidate(address indexed liquidator, address indexed user, address indexed token, euint256 amount);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    /// @notice Add a new token to the lending platform
    /// @param tokenAddress The ERC20 token address
    /// @param initialRate The initial interest rate (APR in basis points)
    function addToken(address tokenAddress, euint32 initialRate) external onlyOwner {
        require(!supportedTokens[tokenAddress].isActive, "Token already supported");

        supportedTokens[tokenAddress] = TokenInfo({
            tokenAddress: tokenAddress,
            totalLiquidity: FHE.asEuint256(0),
            totalBorrowed: FHE.asEuint256(0),
            interestRate: FHE.toEuint256(initialRate),
            isActive: true
        });

        tokenList.push(tokenAddress);
        emit TokenAdded(tokenAddress);
    }

    /// @notice Remove a token from the lending platform
    /// @param tokenAddress The ERC20 token address to remove
    function removeToken(address tokenAddress) external onlyOwner {
        require(supportedTokens[tokenAddress].isActive, "Token not supported");

        // Verify no outstanding loans for this token
        euint256 totalBorrowed = supportedTokens[tokenAddress].totalBorrowed;
        ebool hasOutstandingLoans = FHE.gt(totalBorrowed, FHE.asEuint256(0));
        require(!FHE.decrypt(hasOutstandingLoans), "Token has outstanding loans");

        supportedTokens[tokenAddress].isActive = false;
        emit TokenRemoved(tokenAddress);
    }

    /// @notice Deposit tokens into the lending pool
    /// @param tokenAddress The token to deposit
    /// @param amount The encrypted amount to deposit
    /// @param inputProof The proof for the encrypted amount
    function deposit(
        address tokenAddress,
        externalEuint256 amount,
        bytes calldata inputProof
    ) external {
        require(supportedTokens[tokenAddress].isActive, "Token not supported");

        euint256 encryptedAmount = FHE.fromExternal(amount, inputProof);
        
        // Update user position
        UserPosition storage position = userPositions[msg.sender][tokenAddress];
        position.suppliedAmount = FHE.add(position.suppliedAmount, encryptedAmount);
        position.collateralValue = FHE.add(position.collateralValue, encryptedAmount);

        // Update pool liquidity
        supportedTokens[tokenAddress].totalLiquidity = FHE.add(
            supportedTokens[tokenAddress].totalLiquidity,
            encryptedAmount
        );

        // Transfer tokens from user (in clear)
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), FHE.decrypt(encryptedAmount));

        // Allow operations on encrypted values
        FHE.allowThis(position.suppliedAmount);
        FHE.allowThis(position.collateralValue);
        FHE.allowThis(supportedTokens[tokenAddress].totalLiquidity);

        emit Deposit(msg.sender, tokenAddress, encryptedAmount);
    }

    /// @notice Withdraw tokens from the lending pool
    /// @param tokenAddress The token to withdraw
    /// @param amount The encrypted amount to withdraw
    /// @param inputProof The proof for the encrypted amount
    function withdraw(
        address tokenAddress,
        externalEuint256 amount,
        bytes calldata inputProof
    ) external {
        require(supportedTokens[tokenAddress].isActive, "Token not supported");

        euint256 encryptedAmount = FHE.fromExternal(amount, inputProof);
        UserPosition storage position = userPositions[msg.sender][tokenAddress];

        // Verify sufficient balance
        ebool canWithdraw = FHE.lte(encryptedAmount, position.suppliedAmount);
        require(FHE.decrypt(canWithdraw), "Insufficient balance");

        // Verify withdrawal doesn't put borrow position at risk
        euint256 newCollateral = FHE.sub(position.collateralValue, encryptedAmount);
        euint256 borrowedValue = position.borrowedAmount;
        ebool isSafe = _checkCollateralRatio(newCollateral, borrowedValue);
        require(FHE.decrypt(isSafe), "Withdrawal would make position unsafe");

        // Update positions
        position.suppliedAmount = FHE.sub(position.suppliedAmount, encryptedAmount);
        position.collateralValue = newCollateral;
        supportedTokens[tokenAddress].totalLiquidity = FHE.sub(
            supportedTokens[tokenAddress].totalLiquidity,
            encryptedAmount
        );

        // Transfer tokens to user (in clear)
        IERC20(tokenAddress).transfer(msg.sender, FHE.decrypt(encryptedAmount));

        // Allow operations on encrypted values
        FHE.allowThis(position.suppliedAmount);
        FHE.allowThis(position.collateralValue);
        FHE.allowThis(supportedTokens[tokenAddress].totalLiquidity);

        emit Withdraw(msg.sender, tokenAddress, encryptedAmount);
    }

    /// @notice Borrow tokens from the lending pool
    /// @param tokenAddress The token to borrow
    /// @param amount The encrypted amount to borrow
    /// @param inputProof The proof for the encrypted amount
    function borrow(
        address tokenAddress,
        externalEuint256 amount,
        bytes calldata inputProof
    ) external {
        require(supportedTokens[tokenAddress].isActive, "Token not supported");

        euint256 encryptedAmount = FHE.fromExternal(amount, inputProof);
        UserPosition storage position = userPositions[msg.sender][tokenAddress];

        // Verify sufficient liquidity
        ebool hasLiquidity = FHE.lte(encryptedAmount, supportedTokens[tokenAddress].totalLiquidity);
        require(FHE.decrypt(hasLiquidity), "Insufficient liquidity");

        // Verify collateral ratio remains safe
        euint256 newBorrowed = FHE.add(position.borrowedAmount, encryptedAmount);
        ebool isSafe = _checkCollateralRatio(position.collateralValue, newBorrowed);
        require(FHE.decrypt(isSafe), "Borrow would exceed collateral limit");

        // Update positions
        position.borrowedAmount = newBorrowed;
        supportedTokens[tokenAddress].totalLiquidity = FHE.sub(
            supportedTokens[tokenAddress].totalLiquidity,
            encryptedAmount
        );
        supportedTokens[tokenAddress].totalBorrowed = FHE.add(
            supportedTokens[tokenAddress].totalBorrowed,
            encryptedAmount
        );

        // Transfer tokens to user (in clear)
        IERC20(tokenAddress).transfer(msg.sender, FHE.decrypt(encryptedAmount));

        // Allow operations on encrypted values
        FHE.allowThis(position.borrowedAmount);
        FHE.allowThis(supportedTokens[tokenAddress].totalLiquidity);
        FHE.allowThis(supportedTokens[tokenAddress].totalBorrowed);

        emit Borrow(msg.sender, tokenAddress, encryptedAmount);
    }

    /// @notice Repay borrowed tokens
    /// @param tokenAddress The token to repay
    /// @param amount The encrypted amount to repay
    /// @param inputProof The proof for the encrypted amount
    function repay(
        address tokenAddress,
        externalEuint256 amount,
        bytes calldata inputProof
    ) external {
        require(supportedTokens[tokenAddress].isActive, "Token not supported");

        euint256 encryptedAmount = FHE.fromExternal(amount, inputProof);
        UserPosition storage position = userPositions[msg.sender][tokenAddress];

        // Verify debt exists
        ebool hasDebt = FHE.gt(position.borrowedAmount, FHE.asEuint256(0));
        require(FHE.decrypt(hasDebt), "No debt to repay");

        // Calculate amount to actually repay (can't repay more than owed)
        euint256 repaymentAmount = FHE.min(encryptedAmount, position.borrowedAmount);

        // Update positions
        position.borrowedAmount = FHE.sub(position.borrowedAmount, repaymentAmount);
        supportedTokens[tokenAddress].totalLiquidity = FHE.add(
            supportedTokens[tokenAddress].totalLiquidity,
            repaymentAmount
        );
        supportedTokens[tokenAddress].totalBorrowed = FHE.sub(
            supportedTokens[tokenAddress].totalBorrowed,
            repaymentAmount
        );

        // Transfer tokens from user (in clear)
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), FHE.decrypt(repaymentAmount));

        // Allow operations on encrypted values
        FHE.allowThis(position.borrowedAmount);
        FHE.allowThis(supportedTokens[tokenAddress].totalLiquidity);
        FHE.allowThis(supportedTokens[tokenAddress].totalBorrowed);

        emit Repay(msg.sender, tokenAddress, repaymentAmount);
    }

    /// @notice Liquidate an undercollateralized position
    /// @param user The user with the undercollateralized position
    /// @param tokenAddress The token to liquidate
    function liquidate(address user, address tokenAddress) external {
        require(supportedTokens[tokenAddress].isActive, "Token not supported");

        UserPosition storage position = userPositions[user][tokenAddress];
        
        // Check if position is liquidatable
        ebool isLiquidatable = _isLiquidatable(position.collateralValue, position.borrowedAmount);
        require(FHE.decrypt(isLiquidatable), "Position is not liquidatable");

        // Calculate liquidation amount (up to 50% of debt)
        euint256 halfDebt = FHE.div(position.borrowedAmount, FHE.asEuint256(2));
        euint256 liquidationAmount = FHE.min(halfDebt, position.collateralValue);

        // Update positions
        position.borrowedAmount = FHE.sub(position.borrowedAmount, liquidationAmount);
        position.collateralValue = FHE.sub(position.collateralValue, liquidationAmount);
        supportedTokens[tokenAddress].totalBorrowed = FHE.sub(
            supportedTokens[tokenAddress].totalBorrowed,
            liquidationAmount
        );

        // Transfer collateral to liquidator (in clear)
        IERC20(tokenAddress).transfer(msg.sender, FHE.decrypt(liquidationAmount));

        // Allow operations on encrypted values
        FHE.allowThis(position.borrowedAmount);
        FHE.allowThis(position.collateralValue);
        FHE.allowThis(supportedTokens[tokenAddress].totalBorrowed);

        emit Liquidate(msg.sender, user, tokenAddress, liquidationAmount);
    }

    /// @notice Internal function to check collateral ratio
    /// @param collateral The collateral amount
    /// @param borrowed The borrowed amount
    /// @return ebool True if collateral ratio is safe
    function _checkCollateralRatio(euint256 collateral, euint256 borrowed) internal view returns (ebool) {
        euint256 collateralRatio = FHE.mul(FHE.asEuint256(10000), FHE.div(borrowed, collateral));
        return FHE.lte(collateralRatio, LTV_RATIO);
    }

    /// @notice Internal function to check if position is liquidatable
    /// @param collateral The collateral amount
    /// @param borrowed The borrowed amount
    /// @return ebool True if position is liquidatable
    function _isLiquidatable(euint256 collateral, euint256 borrowed) internal view returns (ebool) {
        euint256 collateralRatio = FHE.mul(FHE.asEuint256(10000), FHE.div(borrowed, collateral));
        return FHE.gt(collateralRatio, LIQUIDATION_THRESHOLD);
    }

    /// @notice Get list of supported tokens
    /// @return Array of token addresses
    function getSupportedTokens() external view returns (address[] memory) {
        return tokenList;
    }
}
