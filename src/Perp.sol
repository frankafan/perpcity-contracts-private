// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { vAMM } from "./vAMM.sol";
import { Vault } from "./Vault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IBeacon } from "./interfaces/IBeacon.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract Perp is Initializable, UUPSUpgradeable, OwnableUpgradeable, Vault, vAMM {
    struct Position {
        bool isLong;
        uint256 size; // number of perp assets held, with PERP_PRECISION
        uint256 margin; // USDC put up as collateral
        uint256 entryValue; // USDC value of the position at the time of entry; used to calculate pnl
        int256 entryCumulativeFunding; // cumulativeFunding at the time of entry; used to calculate funding
        uint256 shares; // shares minted to this contract when position was opened
    }

    mapping(address holder => Position position) public positions;

    // USDC payed (or received) per second per position size due to funding, with PRECISION
    // to get a daily percentage, multiply by 86400 (seconds in a day), divide by markPrice and by PRECISION
    int256 public fundingRate;

    // USDC owed (or owed to) since contract deployment per position size due to funding
    // + means longs owe shorts, - means shorts owe longs
    int256 public cumulativeFunding;

    uint256 public lastFundingUpdate;

    // beacon used to get the index price
    IBeacon public beacon;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MIN_POSITION_SIZE = 1e17; // 0.1 PERPs
    uint256 public constant MIN_MARGIN = 5e6; // 5 USDC
    uint256 public constant MAX_MARGIN = 100e6; // 100 USDC
    uint256 public constant MAX_LEVERAGE = 10; // 10x
    uint256 public constant FUNDING_FEE_PERCENTAGE = 1e16; // 1% or 0.01
    uint256 public constant TRADING_FEE_PERCENTAGE = 1e16; // 1% or 0.01
    uint256 public constant LIQUIDATION_FEE_PERCENTAGE = 25e15; // 2.5% or 0.025
    uint256 public constant LIQUIDATION_MARGIN_RATIO = 1e17; // 10% or 0.1

    event MarketCreated(address beacon, uint256 indexPrice);
    event PositionOpened(
        address indexed holder,
        bool isLong,
        uint256 size,
        uint256 margin,
        uint256 entryValue,
        int256 entryCumulativeFunding,
        uint256 newMarkPrice
    );
    event PositionClosed(
        address indexed holder,
        bool isLong,
        uint256 size,
        uint256 margin,
        uint256 exitValue,
        int256 exitCumulativeFunding,
        uint256 newMarkPrice,
        bool isLiquidation
    );
    event FundingRateUpdated(int256 fundingRate);

    error PositionAlreadyExists();
    error PositionSizeTooLow();
    error MarginTooLow();
    error MarginTooHigh();
    error InsufficientBuyingPower();
    error PositionNotFound();
    error PositionLiquidatable();
    error PositionNotLiquidatable();
    error UnauthorizedClose();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 usdcToken,
        string memory vaultTokenName,
        string memory vaultTokenSymbol,
        uint256 indexPrice,
        IBeacon _beacon,
        address initialOwner
    )
        public
        initializer
    {
        __UUPSUpgradeable_init();
        __Ownable_init(initialOwner);

        // Initialize DebtVault and vAMM
        __DebtVault_init(usdcToken, vaultTokenName, vaultTokenSymbol);
        __vAMM_init(indexPrice);

        beacon = _beacon;
        emit MarketCreated(address(beacon), indexPrice);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner { }

    function openPosition(bool isLong, uint256 size, uint256 margin) external {
        if (positions[msg.sender].size > 0) revert PositionAlreadyExists();
        if (size < MIN_POSITION_SIZE) revert PositionSizeTooLow();
        if (margin < MIN_MARGIN) revert MarginTooLow();
        if (margin > MAX_MARGIN) revert MarginTooHigh();

        // deposit margin into DebtVault so that LPs can't claim it as yield
        uint256 shares = deposit(margin, address(this));

        // update vAMM supplies with requested size and receive USDC value of position
        uint256 requiredBuyingPower = _changePerpSupply(isLong, size);
        // check if margin (with at most MAX_LEVERAGE) provides enough buying power
        if (margin * MAX_LEVERAGE < requiredBuyingPower) revert InsufficientBuyingPower();

        _updateCumulativeFunding();
        _updateFundingRate();

        positions[msg.sender] = Position(isLong, size, margin, requiredBuyingPower, cumulativeFunding, shares);
        emit PositionOpened(msg.sender, isLong, size, margin, requiredBuyingPower, cumulativeFunding, markPrice());
    }

    // used to close or liquidate a position
    function closePosition(address holder) external {
        Position memory position = positions[holder];
        if (position.size == 0) revert PositionNotFound();

        // update vAMM supplies with position size and receive current USDC value of position
        uint256 positionValue = _changePerpSupply(!position.isLong, position.size);

        int256 pnl = int256(positionValue) - int256(position.entryValue);
        if (!position.isLong) pnl = -pnl;

        _updateCumulativeFunding();
        _updateFundingRate();

        // funding per position size calculated as change in cumulativeFunding since entry, negated if long
        int256 fundingDifference = cumulativeFunding - position.entryCumulativeFunding;
        // PERP_PRECISION cancels out position.size PRECISION
        int256 funding = fundingDifference * int256(position.size) / int256(PERP_PRECISION);
        if (position.isLong) funding = -funding;

        // if the trader is paying funding, charge a fee
        int256 fundingFee = 0;
        if (funding < 0) {
            fundingFee = funding * int256(FUNDING_FEE_PERCENTAGE) / int256(PRECISION);
            fundingFee = -fundingFee;
        }

        int256 leftoverMargin = int256(position.margin) + funding + pnl;
        if (leftoverMargin < 0) leftoverMargin = 0;

        uint256 marginRatio = Math.mulDiv(uint256(leftoverMargin), PRECISION, positionValue);
        bool isLiquidatable = marginRatio < LIQUIDATION_MARGIN_RATIO;

        // if position is not liquidatable, only the holder can close it
        if (!isLiquidatable && msg.sender != holder) revert UnauthorizedClose();

        // if position is liquidatable, charge liquidation fee, otherwise charge trading fee
        uint256 fee = isLiquidatable
            ? Math.mulDiv(positionValue, LIQUIDATION_FEE_PERCENTAGE, PRECISION)
            : Math.mulDiv(positionValue, TRADING_FEE_PERCENTAGE, PRECISION);

        int256 netPayout = leftoverMargin - int256(fee) - fundingFee;
        if (netPayout < 0) netPayout = 0;

        // transfer netPayout to position holder
        IERC20(asset()).transfer(holder, uint256(netPayout));

        // if a liquidation, pay the liquidator half of the liquidation fee
        if (isLiquidatable) {
            uint256 liquidatorPayment = fee / 2;
            IERC20(asset()).transfer(msg.sender, liquidatorPayment);
        }

        // burn vault tokens so yield is not stolen from LPs
        _burn(address(this), position.shares);

        emit PositionClosed(
            holder,
            position.isLong,
            position.size,
            position.margin,
            positionValue,
            cumulativeFunding,
            markPrice(),
            isLiquidatable
        );
        delete positions[holder];
    }

    // incorporates funding owed (or owed to) since last funding update to cumulativeFunding
    function _updateCumulativeFunding() internal {
        uint256 timeSinceLastUpdate = block.timestamp - lastFundingUpdate;
        // funding owed per second * time since last update (in seconds); PRECISION cancels out fundingRate PRECISION
        int256 fundingUpdate = fundingRate * int256(timeSinceLastUpdate) / int256(PRECISION);
        cumulativeFunding += fundingUpdate;
        lastFundingUpdate = block.timestamp;
    }

    // updates fundingRate based on the difference between markPrice and indexPrice
    function _updateFundingRate() internal {
        int256 markPrice = int256(markPrice());
        IERC20(asset()).approve(address(beacon), beacon.getFee());
        int256 indexPrice = int256(beacon.getData());
        // |markPrice - indexPrice| would be payed (or received) over the next 1 day if fundingRate stayed constant
        fundingRate = (markPrice - indexPrice) * int256(PRECISION) / 1 days;
        emit FundingRateUpdated(fundingRate);
    }

    function previewLiquidationPrice(
        bool isLong,
        uint256 size,
        uint256 margin
    )
        external
        view
        returns (int256 liquidationPrice)
    {
        uint256 positionValue = previewChangePerpSupply(isLong, size);
        return _calculateLiquidationPrice(isLong, size, int256(margin), int256(positionValue));
    }

    function previewLiquidationPrice(address holder) external view returns (int256 liquidationPrice) {
        Position memory position = positions[holder];
        (int256 leftoverMargin,,,) = previewLeftoverMargin(holder);
        uint256 positionValue = previewChangePerpSupply(!position.isLong, position.size);
        return _calculateLiquidationPrice(position.isLong, position.size, leftoverMargin, int256(positionValue));
    }

    function _calculateLiquidationPrice(
        bool isLong,
        uint256 size,
        int256 margin,
        int256 positionValue
    )
        internal
        pure
        returns (int256)
    {
        int256 positionValueAtLiquidation;
        if (isLong) {
            // liquidate when margin + (positionValueAtLiq - positionValue) = liquidationRatio * positionValueAtLiq
            positionValueAtLiquidation =
                (margin - positionValue) * int256(PRECISION) / (int256(LIQUIDATION_MARGIN_RATIO) - int256(PRECISION));
        } else {
            // liquidate when margin + (positionValue - positionValueAtLiq) = liquidationRatio * positionValueAtLiq
            positionValueAtLiquidation =
                (margin + positionValue) * int256(PRECISION) / (int256(LIQUIDATION_MARGIN_RATIO) + int256(PRECISION));
        }
        return positionValueAtLiquidation * int256(PRECISION) / int256(size);
    }

    function previewIsLiquidatable(address holder) external view returns (bool liquidatable) {
        Position memory position = positions[holder];

        if (position.size == 0) revert PositionNotFound();

        uint256 positionValue = previewChangePerpSupply(!position.isLong, position.size);

        int256 pnl = int256(positionValue) - int256(position.entryValue);
        if (!position.isLong) pnl = -pnl;

        int256 fundingDifference = _simulateUpdateCumulativeFunding() - position.entryCumulativeFunding;
        int256 funding = fundingDifference * int256(position.size) / int256(PERP_PRECISION);
        if (position.isLong) funding = -funding;

        int256 leftoverMargin = int256(position.margin) + funding + pnl;
        if (leftoverMargin < 0) leftoverMargin = 0;

        uint256 marginRatio = Math.mulDiv(uint256(leftoverMargin), PRECISION, positionValue);
        liquidatable = marginRatio < LIQUIDATION_MARGIN_RATIO;
    }

    function previewLeftoverMargin(address holder)
        public
        view
        returns (int256 leftoverMargin, int256 funding, int256 pnl, uint256 marginRatio)
    {
        Position memory position = positions[holder];
        uint256 positionValue = previewChangePerpSupply(!position.isLong, position.size);

        pnl = int256(positionValue) - int256(position.entryValue);
        if (!position.isLong) pnl = -pnl;

        int256 fundingDifference = _simulateUpdateCumulativeFunding() - position.entryCumulativeFunding;
        funding = fundingDifference * int256(position.size) / int256(PERP_PRECISION);
        if (position.isLong) funding = -funding;

        leftoverMargin = int256(position.margin) + funding + pnl;
        if (leftoverMargin < 0) leftoverMargin = 0;

        marginRatio = Math.mulDiv(uint256(leftoverMargin), PRECISION, positionValue);
    }

    function _simulateUpdateCumulativeFunding() internal view returns (int256 simulatedCumulativeFunding) {
        uint256 timeSinceLastUpdate = block.timestamp - lastFundingUpdate;
        int256 fundingUpdate = fundingRate * int256(timeSinceLastUpdate) / int256(PRECISION);
        int256 fundingFee = fundingUpdate * int256(FUNDING_FEE_PERCENTAGE) / int256(PRECISION);
        simulatedCumulativeFunding = cumulativeFunding + fundingUpdate + fundingFee;
    }
}
