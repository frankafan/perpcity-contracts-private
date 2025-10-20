// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

// TODO: add comments / fix for modularity

uint256 constant UINT_Q96 = 0x1000000000000000000000000;
int256 constant INT_Q96 = 0x1000000000000000000000000;
uint256 constant SCALE_1E6 = 1e6;

int24 constant TICK_SPACING = 30;
uint32 constant TWAVG_WINDOW = 1 hours;
uint24 constant MIN_OPENING_MARGIN = 1e6; // 1 USDC
int256 constant FUNDING_INTERVAL = 1 days;