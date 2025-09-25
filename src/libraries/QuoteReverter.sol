// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

library QuoteReverter {
    error Quote(
        int256 perpDelta, int256 usdDelta, uint256 creatorFeeAmt, uint256 insuranceFeeAmt, uint256 lpFeeAmt
    );

    function revertQuote(
        int256 perpDelta, 
        int256 usdDelta,
        uint256 creatorFeeAmt, 
        uint256 insuranceFeeAmt, 
        uint256 lpFeeAmt
    )
        internal
        pure
    {
        revert Quote(perpDelta, usdDelta, creatorFeeAmt, insuranceFeeAmt, lpFeeAmt);
    }

    function parseQuote(bytes memory reason)
        internal
        pure
        returns (bool success, int256 perpDelta, int256 usdDelta, uint256 creatorFeeAmt, uint256 insuranceFeeAmt, uint256 lpFeeAmt)
    {
        if (parseSelector(reason) != Quote.selector) {
            return (false, 0, 0, 0, 0, 0);
        }

        // equivalent: (, success, perpDelta, usdDelta, creatorFeeAmt, insuranceFeeAmt, lpFeeAmt) = abi.decode(
        //     reason,
        //     (bytes4, int256, int256, uint256, uint256, uint256)
        // );

        // reason -> reason+0x1f is the length of the reason string
        // reason+0x20 -> reason+0x23 is the selector of Quote
        // reason+0x24 -> reason+0x43 is perpDelta
        // reason+0x44 -> reason+0x63 is usdDelta
        // reason+0x64 -> reason+0x83 is creatorFeeAmt
        // reason+0x84 -> reason+0xa3 is insuranceFeeAmt
        // reason+0xa4 -> reason+0xc3 is lpFeeAmt
        success = true;
        assembly ("memory-safe") {
            perpDelta := mload(add(reason, 0x24))
            usdDelta := mload(add(reason, 0x44))
            creatorFeeAmt := mload(add(reason, 0x64))
            insuranceFeeAmt := mload(add(reason, 0x84))
            lpFeeAmt := mload(add(reason, 0xa4))
        }
    }

    function parseSelector(bytes memory result) internal pure returns (bytes4 selector) {
        // equivalent: (selector,) = abi.decode(result, (bytes4, int256, int256, uint256, uint256, uint256));
        assembly ("memory-safe") {
            selector := mload(add(result, 0x20))
        }
    }
}
