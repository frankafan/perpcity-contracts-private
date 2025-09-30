// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

uint256 constant MAX_CARDINALITY = 65_535;

int24 constant TICK_SPACING = 30;
uint32 constant INITIAL_CARDINALITY_NEXT = 100;
uint32 constant MAKER_LOCKUP_PERIOD = 7 days;
uint32 constant FUNDING_INTERVAL = 1 days;
uint32 constant TWAP_WINDOW = 1 hours;
uint24 constant CREATOR_FEE = 0.0001e6; // 0.01%
uint24 constant INSURANCE_FEE = 100; // 0.01%
uint128 constant SQRT_PRICE_LOWER_MULTI_X96 = 75162434512514379355924140471; // sqrt(1 - 0.1) * 2^96
uint128 constant SQRT_PRICE_UPPER_MULTI_X96 = 83095197869223157896060286991; // sqrt(1 + 0.1) * 2^96
uint24 constant MIN_OPENING_MARGIN = 1e6; // 1 USDC
uint24 constant MIN_MAKER_OPENING_MARGIN_RATIO = 0.9e6; // 90% / 1.11x leverage
uint24 constant MAX_MAKER_OPENING_MARGIN_RATIO = 2e6; // 200% / 0.5x leverage
uint24 constant MAKER_LIQUIDATION_MARGIN_RATIO = 0.5e6; // 50% / 2x leverage
uint24 constant MIN_TAKER_OPENING_MARGIN_RATIO = 0.1e6; // 10% / 10x leverage
uint24 constant MAX_TAKER_OPENING_MARGIN_RATIO = 2e6; // 200% / 0.5x leverage
uint24 constant TAKER_LIQUIDATION_MARGIN_RATIO = 0.05e6; // 5% / 20x leverage
uint24 constant LIQUIDATION_FEE = 0.01e6; // 1%
uint24 constant LIQUIDATOR_FEE_SPLIT = 0.5e6; // 50%
uint24 constant START_FEE = 0.01e6; // 1%
uint24 constant TARGET_FEE = 0.0001e6; // 0.01%
uint24 constant DECAY = 15000000;
uint24 constant VOLATILITY_SCALER = 0.2e6; // 0.2
uint24 constant MAX_FEE_MULTIPLIER = 2e6; // 200%

uint256 constant UINT_Q96 = 0x1000000000000000000000000;
int256 constant INT_Q96 = 0x1000000000000000000000000;
uint256 constant UINT_Q192 = 0x1000000000000000000000000000000000000000000000000;

uint256 constant SCALE_1E6 = 1e6;
