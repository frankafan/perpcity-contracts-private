// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

/// @title QuoteReverter
/// @notice Library for parsing data from revert reasons so that accurate data about transaction outcomes can be
/// obtained without changing state
library QuoteReverter {
    /* STRUCTS */

    /// @notice Data about the outcome of opening a position
    /// @param perpDelta The delta in perp contracts after the transaction
    /// @param usdDelta The delta in usd after the transaction
    /// @param creatorFee The amount paid by the holder to the creator due to the creator fee
    /// @param insuranceFee The amount paid by the holder to the insurance fund due to the insurance fee
    /// @param lpFee The amount paid by the holder to the liquidity providers due to the lp fee
    struct OpenQuote {
        int256 perpDelta;
        int256 usdDelta;
        uint256 creatorFee;
        uint256 insuranceFee;
        uint256 lpFee;
    }

    /// @notice Data about the outcome of closing a position
    /// @param pnl The pnl of the position at close
    /// @param funding The funding payment of the position at close
    /// @param effectiveMargin The margin of the position after pnl, funding, and fees
    /// @param wasLiquidated Whether the position was liquidated by the close call
    struct CloseQuote {
        int256 pnl;
        int256 funding;
        uint256 effectiveMargin;
        bool wasLiquidated;
    }

    /* ERRORS */

    /// @notice Thrown when state change is not desired on opening a position. This should be caught by a try-catch
    /// @param quote The data about the outcome of the open
    error RevertOpenQuote(OpenQuote quote);

    /// @notice Thrown when state change is not desired on closing a position. This should be caught by a try-catch
    /// @param quote The data about the outcome of the close
    error RevertCloseQuote(CloseQuote quote);

    /* FUNCTIONS */

    /// @notice Parses the reason for a revert and returns the data in it
    /// @dev If the error is not RevertOpenQuote, then the original transaction would have failed
    /// @param reason The reason for the revert
    /// @return success Whether the transaction that caused the revert would have been successful
    /// @return quote The data about the outcome of the open
    function parseOpenQuote(bytes memory reason) internal pure returns (bool success, OpenQuote memory quote) {
        if (parseSelector(reason) != RevertOpenQuote.selector) return (false, OpenQuote(0, 0, 0, 0, 0));
        success = true;

        int256 perpDelta;
        int256 usdDelta;
        uint256 creatorFee;
        uint256 insuranceFee;
        uint256 lpFee;

        // reason -> reason+0x1f is the length of the reason string
        // reason+0x20 -> reason+0x23 is the selector
        // reason+0x24 -> reason+0x43 is perpDelta
        // reason+0x44 -> reason+0x63 is usdDelta
        // reason+0x64 -> reason+0x83 is creatorFee
        // reason+0x84 -> reason+0xa3 is insuranceFee
        // reason+0xa4 -> reason+0xc3 is lpFee
        assembly ("memory-safe") {
            perpDelta := mload(add(reason, 0x24))
            usdDelta := mload(add(reason, 0x44))
            creatorFee := mload(add(reason, 0x64))
            insuranceFee := mload(add(reason, 0x84))
            lpFee := mload(add(reason, 0xa4))
        }

        quote = OpenQuote(perpDelta, usdDelta, creatorFee, insuranceFee, lpFee);
    }

    /// @notice Parses the reason for a revert and returns the data in it
    /// @dev If the error is not RevertCloseQuote, then the original transaction would have failed
    /// @param reason The reason for the revert
    /// @return success Whether the transaction that caused the revert would have been successful
    /// @return quote The data about the outcome of the close
    function parseCloseQuote(bytes memory reason) internal pure returns (bool success, CloseQuote memory quote) {
        if (parseSelector(reason) != RevertCloseQuote.selector) return (false, CloseQuote(0, 0, 0, false));
        success = true;

        int256 pnl;
        int256 funding;
        uint256 effectiveMargin;
        bool wasLiquidated;

        // reason -> reason+0x1f is the length of the reason string
        // reason+0x20 -> reason+0x23 is the selector
        // reason+0x24 -> reason+0x43 is pnl
        // reason+0x44 -> reason+0x63 is funding
        // reason+0x64 -> reason+0x83 is effectiveMargin
        // reason+0x84 -> reason+0xa3 is wasLiquidated
        assembly ("memory-safe") {
            pnl := mload(add(reason, 0x24))
            funding := mload(add(reason, 0x44))
            effectiveMargin := mload(add(reason, 0x64))
            wasLiquidated := mload(add(reason, 0x84))
        }

        quote = CloseQuote(pnl, funding, effectiveMargin, wasLiquidated);
    }

    /// @notice Parses the selector from the reason for a revert
    /// @param reason The reason for the revert
    /// @return selector The selector from the reason
    function parseSelector(bytes memory reason) internal pure returns (bytes4 selector) {
        // reason -> reason+0x1f is the length of the reason string
        // reason+0x20 -> reason+0x23 is the selector
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
    }
}
