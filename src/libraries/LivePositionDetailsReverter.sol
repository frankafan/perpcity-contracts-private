// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

library LivePositionDetailsReverter {
    error LivePositionDetails(int256 pnl, int256 funding, int256 effectiveMargin, bool isLiquidatable);
    error UnexpectedRevertBytes(bytes reason);

    function revertLivePositionDetails(
        int256 pnl,
        int256 funding,
        int256 effectiveMargin,
        bool isLiquidatable
    )
        internal
        pure
    {
        revert LivePositionDetails(pnl, funding, effectiveMargin, isLiquidatable);
    }

    function parseLivePositionDetails(bytes memory reason)
        internal
        pure
        returns (int256 pnl, int256 funding, int256 effectiveMargin, bool isLiquidatable)
    {
        if (parseSelector(reason) != LivePositionDetails.selector) {
            revert UnexpectedRevertBytes(reason);
        }

        // equivalent: (, pnl, funding, effectiveMargin, isLiquidatable) = abi.decode(
        //     reason,
        //     (bytes4, int256, int256, int256, bool)
        // );

        // reason -> reason+0x1f is the length of the reason string
        // reason+0x20 -> reason+0x23 is the selector of LivePositionDetails
        // reason+0x24 -> reason+0x43 is pnl
        // reason+0x44 -> reason+0x63 is funding
        // reason+0x64 -> reason+0x83 is effectiveMargin
        // reason+0x84 -> reason+0xa3 is isLiquidatable
        assembly ("memory-safe") {
            pnl := mload(add(reason, 0x24))
            funding := mload(add(reason, 0x44))
            effectiveMargin := mload(add(reason, 0x64))
            isLiquidatable := mload(add(reason, 0x84))
        }
    }

    function parseSelector(bytes memory result) internal pure returns (bytes4 selector) {
        // equivalent: (selector,) = abi.decode(result, (bytes4, int256, int256, int256, bool));
        assembly ("memory-safe") {
            selector := mload(add(result, 0x20))
        }
    }
}
