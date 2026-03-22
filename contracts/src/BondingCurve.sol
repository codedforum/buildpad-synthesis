// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BondingCurveToken
/// @notice ERC20 token with mint/burn controlled by the bonding curve contract.
contract BondingCurveToken is ERC20 {
    address public immutable curve;
    string public tokenURI;

    error OnlyCurve();

    modifier onlyCurve() {
        if (msg.sender != curve) revert OnlyCurve();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        string memory uri_
    ) ERC20(name_, symbol_) {
        curve = msg.sender;
        tokenURI = uri_;
    }

    function mint(address to, uint256 amount) external onlyCurve {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyCurve {
        _burn(from, amount);
    }
}

/// @title BondingCurve
/// @author BuildPad (SmartCodedBot)
/// @notice Discrete step bonding curve with pump.fun-style graduation to Uniswap V4.
///         Buy = mint tokens (ETH goes to pool). Sell = burn tokens (ETH returned).
///         When the pool reaches the graduation threshold, all liquidity migrates
///         to a Uniswap V4 pool via the external Graduator contract.
/// @dev Uses OpenZeppelin ReentrancyGuard. Steps are stored as {rangeTo, price} pairs
///      where `price` is the cost in wei per whole token (1e18 units) at that step.
contract BondingCurve is Ownable, ReentrancyGuard {
    // ─── Types ──────────────────────────────────────────────────────────
    
    /// @notice A single step on the bonding curve.
    /// @param rangeTo Cumulative token supply (in 1e18) at the top of this step.
    /// @param price   Wei per whole token within this step.
    struct BondStep {
        uint256 rangeTo;
        uint256 price;
    }

    enum CurveType { LINEAR, EXPONENTIAL, FLAT }

    // ─── State ──────────────────────────────────────────────────────────
    
    BondingCurveToken public immutable token;
    BondStep[] public steps;

    address public graduator;
    uint256 public graduationThreshold; // Wei of ETH that triggers graduation
    bool public graduated;

    uint256 public poolBalance;         // ETH held in the bonding curve pool
    uint256 public maxSupply;           // Hard cap on token supply (1e18 units)

    uint16 public creatorRoyaltyBps;    // Creator royalty in bps (max 500 = 5%)
    uint16 public constant MAX_ROYALTY_BPS = 500;
    address public creator;
    uint256 public creatorEarnings;     // Accumulated royalties claimable by creator

    // ─── Events ─────────────────────────────────────────────────────────
    
    event TokensBought(address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 newSupply);
    event TokensSold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 newSupply);
    event Graduated(address indexed token, uint256 pooledETH, uint256 tokenSupply);
    event CreatorRoyaltyClaimed(address indexed creator, uint256 amount);
    event GraduatorUpdated(address indexed oldGraduator, address indexed newGraduator);

    // ─── Errors ─────────────────────────────────────────────────────────
    
    error AlreadyGraduated();
    error NotGraduated();
    error SlippageExceeded();
    error ZeroAmount();
    error ExceedsMaxSupply();
    error InvalidSteps();
    error InvalidRoyalty();
    error NoSteps();
    error InsufficientPool();
    error TransferFailed();
    error ZeroAddress();
    error NothingToClaim();

    // ─── Constructor ────────────────────────────────────────────────────

    /// @notice Deploy a new bonding curve with its token.
    /// @param name_          Token name.
    /// @param symbol_        Token symbol.
    /// @param uri_           Token metadata URI.
    /// @param steps_         Ordered array of BondStep (rangeTo must be strictly increasing).
    /// @param graduator_     Address of the BuildPadGraduator contract.
    /// @param threshold_     ETH amount (wei) that triggers graduation.
    /// @param royaltyBps_    Creator royalty in basis points (max 500).
    /// @param creatorAlloc_  Pre-mint amount for creator (in 1e18 token units, 0 for none).
    constructor(
        string memory name_,
        string memory symbol_,
        string memory uri_,
        BondStep[] memory steps_,
        address graduator_,
        uint256 threshold_,
        uint16 royaltyBps_,
        uint256 creatorAlloc_
    ) Ownable(msg.sender) {
        if (graduator_ == address(0)) revert ZeroAddress();
        if (steps_.length == 0) revert NoSteps();
        if (royaltyBps_ > MAX_ROYALTY_BPS) revert InvalidRoyalty();

        // Validate steps are strictly increasing
        uint256 prev;
        for (uint256 i; i < steps_.length; i++) {
            if (steps_[i].rangeTo <= prev) revert InvalidSteps();
            if (steps_[i].price == 0) revert InvalidSteps();
            prev = steps_[i].rangeTo;
            steps.push(steps_[i]);
        }

        token = new BondingCurveToken(name_, symbol_, uri_);
        graduator = graduator_;
        graduationThreshold = threshold_ == 0 ? 2 ether : threshold_;
        creatorRoyaltyBps = royaltyBps_;
        creator = msg.sender;
        maxSupply = steps_[steps_.length - 1].rangeTo;

        // Pre-mint creator allocation
        if (creatorAlloc_ > 0) {
            if (creatorAlloc_ > maxSupply) revert ExceedsMaxSupply();
            token.mint(msg.sender, creatorAlloc_);
        }
    }

    // ─── Modifiers ──────────────────────────────────────────────────────

    modifier notGraduated() {
        if (graduated) revert AlreadyGraduated();
        _;
    }

    // ─── Buy ────────────────────────────────────────────────────────────

    /// @notice Buy tokens by sending ETH. Tokens are minted along the bonding curve.
    /// @param minTokensOut Minimum tokens expected (slippage protection).
    /// @return tokensOut   Actual tokens minted.
    function buy(uint256 minTokensOut) external payable nonReentrant notGraduated returns (uint256 tokensOut) {
        if (msg.value == 0) revert ZeroAmount();

        uint256 ethRemaining = msg.value;

        // Deduct creator royalty
        uint256 royalty;
        if (creatorRoyaltyBps > 0) {
            royalty = (ethRemaining * creatorRoyaltyBps) / 10_000;
            creatorEarnings += royalty;
            ethRemaining -= royalty;
        }

        uint256 currentSupply = token.totalSupply();
        uint256 startSupply = currentSupply;

        // Walk through steps and mint tokens
        for (uint256 i; i < steps.length && ethRemaining > 0; i++) {
            BondStep memory step = steps[i];

            // Skip steps we've already passed
            if (currentSupply >= step.rangeTo) continue;

            // How many tokens can we buy in this step?
            uint256 stepStart = i == 0 ? 0 : steps[i - 1].rangeTo;
            uint256 effectiveStart = currentSupply > stepStart ? currentSupply : stepStart;
            uint256 available = step.rangeTo - effectiveStart;

            // Cost for all available tokens in this step
            uint256 costForAll = (available * step.price) / 1e18;

            if (ethRemaining >= costForAll) {
                // Buy all tokens in this step
                tokensOut += available;
                currentSupply += available;
                ethRemaining -= costForAll;
            } else {
                // Partial fill — buy what we can afford
                uint256 tokensBuyable = (ethRemaining * 1e18) / step.price;
                if (tokensBuyable == 0) break;
                tokensOut += tokensBuyable;
                currentSupply += tokensBuyable;
                ethRemaining = 0;
            }
        }

        if (tokensOut == 0) revert ZeroAmount();
        if (currentSupply > maxSupply) revert ExceedsMaxSupply();
        if (tokensOut < minTokensOut) revert SlippageExceeded();

        // Mint tokens to buyer
        token.mint(msg.sender, tokensOut);
        poolBalance += (msg.value - royalty - ethRemaining);

        // Refund leftover ETH (e.g. if supply cap reached mid-step)
        if (ethRemaining > 0) {
            (bool ok,) = msg.sender.call{value: ethRemaining}("");
            if (!ok) revert TransferFailed();
        }

        emit TokensBought(msg.sender, msg.value - ethRemaining, tokensOut, currentSupply);

        // Check graduation
        if (poolBalance >= graduationThreshold) {
            _graduate();
        }
    }

    // ─── Sell ───────────────────────────────────────────────────────────

    /// @notice Sell tokens back to the bonding curve. Tokens are burned, ETH returned.
    /// @param tokenAmount Tokens to sell (in 1e18 units).
    /// @param minETHOut   Minimum ETH expected (slippage protection).
    /// @return ethOut     Actual ETH returned.
    function sell(uint256 tokenAmount, uint256 minETHOut) external nonReentrant notGraduated returns (uint256 ethOut) {
        if (tokenAmount == 0) revert ZeroAmount();

        uint256 currentSupply = token.totalSupply();
        uint256 remaining = tokenAmount;

        // Walk steps in reverse to calculate ETH return
        for (uint256 i = steps.length; i > 0 && remaining > 0; i--) {
            BondStep memory step = steps[i - 1];
            uint256 stepStart = i == 1 ? 0 : steps[i - 2].rangeTo;

            // Skip steps above current supply
            if (currentSupply <= stepStart) continue;

            uint256 inThisStep = currentSupply - stepStart;
            if (inThisStep > step.rangeTo - stepStart) {
                inThisStep = step.rangeTo - stepStart;
            }

            // Clamp to what's actually above step start
            uint256 effectiveInStep = currentSupply > step.rangeTo ? 0 : currentSupply - stepStart;
            if (effectiveInStep == 0) continue;

            uint256 sellFromStep = remaining > effectiveInStep ? effectiveInStep : remaining;
            uint256 ethForStep = (sellFromStep * step.price) / 1e18;

            ethOut += ethForStep;
            currentSupply -= sellFromStep;
            remaining -= sellFromStep;
        }

        if (ethOut == 0) revert ZeroAmount();
        if (ethOut > poolBalance) revert InsufficientPool();

        // Deduct creator royalty from sell proceeds
        uint256 royalty;
        if (creatorRoyaltyBps > 0) {
            royalty = (ethOut * creatorRoyaltyBps) / 10_000;
            creatorEarnings += royalty;
            ethOut -= royalty;
        }

        if (ethOut < minETHOut) revert SlippageExceeded();

        // Burn tokens, return ETH
        token.burn(msg.sender, tokenAmount);
        poolBalance -= (ethOut + royalty);

        (bool ok,) = msg.sender.call{value: ethOut}("");
        if (!ok) revert TransferFailed();

        emit TokensSold(msg.sender, tokenAmount, ethOut, token.totalSupply());
    }

    // ─── Graduation ─────────────────────────────────────────────────────

    /// @dev Internal graduation — locks curve, sends all ETH + remaining mintable tokens to graduator.
    function _graduate() internal {
        graduated = true;

        uint256 ethToSend = poolBalance;
        poolBalance = 0;

        // Mint remaining tokens (up to maxSupply) for LP pairing
        uint256 currentSupply = token.totalSupply();
        uint256 remainingTokens = maxSupply > currentSupply ? maxSupply - currentSupply : 0;
        if (remainingTokens > 0) {
            token.mint(address(this), remainingTokens);
        }

        uint256 tokenBalance = token.balanceOf(address(this));

        // Approve graduator to pull tokens
        if (tokenBalance > 0) {
            token.approve(graduator, tokenBalance);
        }

        // Call graduator — it handles V4 pool creation + LP
        (bool ok,) = graduator.call{value: ethToSend}(
            abi.encodeWithSignature(
                "graduate(address,uint256)",
                address(token),
                tokenBalance
            )
        );
        if (!ok) revert TransferFailed();

        emit Graduated(address(token), ethToSend, token.totalSupply());
    }

    // ─── Creator Functions ──────────────────────────────────────────────

    /// @notice Creator claims accumulated royalties.
    function claimRoyalties() external {
        if (msg.sender != creator) revert ZeroAddress();
        uint256 amount = creatorEarnings;
        if (amount == 0) revert NothingToClaim();
        creatorEarnings = 0;

        (bool ok,) = creator.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit CreatorRoyaltyClaimed(creator, amount);
    }

    // ─── Owner Functions ────────────────────────────────────────────────

    /// @notice Update the graduator address (only before graduation).
    function setGraduator(address newGraduator) external onlyOwner notGraduated {
        if (newGraduator == address(0)) revert ZeroAddress();
        emit GraduatorUpdated(graduator, newGraduator);
        graduator = newGraduator;
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /// @notice Get all bonding curve steps.
    function getSteps() external view returns (BondStep[] memory) {
        return steps;
    }

    /// @notice Number of steps in the curve.
    function stepCount() external view returns (uint256) {
        return steps.length;
    }

    /// @notice Estimate how many tokens you'd get for a given ETH amount.
    /// @param ethAmount ETH to spend (before royalty).
    /// @return tokensOut Estimated tokens.
    function estimateBuy(uint256 ethAmount) external view returns (uint256 tokensOut) {
        uint256 ethRemaining = ethAmount;
        if (creatorRoyaltyBps > 0) {
            ethRemaining -= (ethRemaining * creatorRoyaltyBps) / 10_000;
        }
        uint256 currentSupply = token.totalSupply();

        for (uint256 i; i < steps.length && ethRemaining > 0; i++) {
            BondStep memory step = steps[i];
            if (currentSupply >= step.rangeTo) continue;

            uint256 stepStart = i == 0 ? 0 : steps[i - 1].rangeTo;
            uint256 effectiveStart = currentSupply > stepStart ? currentSupply : stepStart;
            uint256 available = step.rangeTo - effectiveStart;
            uint256 costForAll = (available * step.price) / 1e18;

            if (ethRemaining >= costForAll) {
                tokensOut += available;
                currentSupply += available;
                ethRemaining -= costForAll;
            } else {
                tokensOut += (ethRemaining * 1e18) / step.price;
                ethRemaining = 0;
            }
        }
    }

    /// @notice Estimate how much ETH you'd get for selling tokens.
    /// @param tokenAmount Tokens to sell.
    /// @return ethOut Estimated ETH (after royalty).
    function estimateSell(uint256 tokenAmount) external view returns (uint256 ethOut) {
        uint256 currentSupply = token.totalSupply();
        uint256 remaining = tokenAmount;
        uint256 grossETH;

        for (uint256 i = steps.length; i > 0 && remaining > 0; i--) {
            BondStep memory step = steps[i - 1];
            uint256 stepStart = i == 1 ? 0 : steps[i - 2].rangeTo;
            if (currentSupply <= stepStart) continue;

            uint256 effectiveInStep = currentSupply > step.rangeTo ? 0 : currentSupply - stepStart;
            if (effectiveInStep == 0) continue;

            uint256 sellFromStep = remaining > effectiveInStep ? effectiveInStep : remaining;
            grossETH += (sellFromStep * step.price) / 1e18;
            currentSupply -= sellFromStep;
            remaining -= sellFromStep;
        }

        if (creatorRoyaltyBps > 0) {
            grossETH -= (grossETH * creatorRoyaltyBps) / 10_000;
        }
        ethOut = grossETH;
    }

    /// @notice Current price per token at the active step.
    function currentPrice() external view returns (uint256) {
        uint256 supply = token.totalSupply();
        for (uint256 i; i < steps.length; i++) {
            if (supply < steps[i].rangeTo) return steps[i].price;
        }
        return steps[steps.length - 1].price;
    }

    /// @notice How much more ETH until graduation.
    function ethUntilGraduation() external view returns (uint256) {
        if (graduated || poolBalance >= graduationThreshold) return 0;
        return graduationThreshold - poolBalance;
    }

    // ─── Curve Generators (Pure Helpers) ────────────────────────────────

    /// @notice Generate linear curve steps.
    /// @param numSteps    Number of discrete steps.
    /// @param totalSupply Max token supply (1e18 units).
    /// @param startPrice  Price at step 0 (wei per token).
    /// @param endPrice    Price at final step (wei per token).
    function generateLinearSteps(
        uint256 numSteps,
        uint256 totalSupply,
        uint256 startPrice,
        uint256 endPrice
    ) external pure returns (BondStep[] memory result) {
        result = new BondStep[](numSteps);
        uint256 supplyPerStep = totalSupply / numSteps;
        uint256 priceIncrement = numSteps > 1
            ? (endPrice - startPrice) / (numSteps - 1)
            : 0;

        for (uint256 i; i < numSteps; i++) {
            result[i] = BondStep({
                rangeTo: supplyPerStep * (i + 1),
                price: startPrice + (priceIncrement * i)
            });
        }
        // Ensure last step covers full supply
        result[numSteps - 1].rangeTo = totalSupply;
    }

    /// @notice Generate exponential curve steps.
    /// @param numSteps    Number of discrete steps.
    /// @param totalSupply Max token supply (1e18 units).
    /// @param startPrice  Price at step 0 (wei per token).
    /// @param multiplier  Scaled by 1e4 (e.g., 15000 = 1.5x per step).
    function generateExponentialSteps(
        uint256 numSteps,
        uint256 totalSupply,
        uint256 startPrice,
        uint256 multiplier
    ) external pure returns (BondStep[] memory result) {
        result = new BondStep[](numSteps);
        uint256 supplyPerStep = totalSupply / numSteps;
        uint256 price = startPrice;

        for (uint256 i; i < numSteps; i++) {
            result[i] = BondStep({
                rangeTo: supplyPerStep * (i + 1),
                price: price
            });
            price = (price * multiplier) / 10_000;
        }
        result[numSteps - 1].rangeTo = totalSupply;
    }

    /// @notice Generate flat curve steps (constant price).
    /// @param totalSupply Max token supply (1e18 units).
    /// @param flatPrice   Constant price (wei per token).
    function generateFlatSteps(
        uint256 totalSupply,
        uint256 flatPrice
    ) external pure returns (BondStep[] memory result) {
        result = new BondStep[](1);
        result[0] = BondStep({rangeTo: totalSupply, price: flatPrice});
    }

    // ─── Receive ────────────────────────────────────────────────────────

    /// @dev Accept ETH only from graduator (refunds) or via buy().
    receive() external payable {}
}
