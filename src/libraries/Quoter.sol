// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

/// @title Quoter
/// @notice Library for parsing data from revert reasons so that accurate data about transaction outcomes can be
/// obtained without changing state
library Quoter {
    /* ERRORS */

    /// @notice Thrown when state change is not desired on opening a position. This should be caught by a try-catch
    /// @param perpDelta The movement of perp contracts during the transaction
    /// @param usdDelta The movement of usd during the transaction
    error OpenQuote(int256 perpDelta, int256 usdDelta);

    /// @notice Thrown when state change is not desired on closing a position. This should be caught by a try-catch
    /// @param pnl The pnl of the position at close
    /// @param funding The funding payment of the position at close
    /// @param netMargin The margin of the position after pnl, funding, and fees
    /// @param wasLiquidated Whether the position was liquidated by the close call
    error CloseQuote(int256 pnl, int256 funding, uint256 netMargin, bool wasLiquidated);

    /* FUNCTIONS */

    /// @notice Parses the reason for a revert and returns the data in it
    /// @dev If the error is not RevertOpenQuote, then the original transaction would have failed
    /// @param reason The reason for the revert
    /// @return success Whether the transaction that caused the revert would have been successful
    /// @return perpDelta The movement of perp contracts during the transaction
    /// @return usdDelta The movement of usd during the transaction
    function parseOpen(bytes memory reason) internal pure returns (bool success, int256 perpDelta, int256 usdDelta) {
        if (parseSelector(reason) != OpenQuote.selector) return (false, 0, 0);
        success = true;

        // reason -> reason+0x1f is the length of the reason string
        // reason+0x20 -> reason+0x23 is the selector
        // reason+0x24 -> reason+0x43 is perpDelta
        // reason+0x44 -> reason+0x63 is usdDelta
        assembly ("memory-safe") {
            perpDelta := mload(add(reason, 0x24))
            usdDelta := mload(add(reason, 0x44))
        }
    }

    /// @notice Parses the reason for a revert and returns the data in it
    /// @dev If the error is not RevertCloseQuote, then the original transaction would have failed
    /// @param reason The reason for the revert
    /// @return success Whether the transaction that caused the revert would have been successful
    /// @return pnl The pnl of the position at close
    /// @return funding The funding payment of the position at close
    /// @return netMargin The margin of the position after pnl, funding, and fees
    /// @return wasLiquidated Whether the position was liquidated by the close call
    function parseClose(bytes memory reason)
        internal
        pure
        returns (bool success, int256 pnl, int256 funding, uint256 netMargin, bool wasLiquidated)
    {
        if (parseSelector(reason) != CloseQuote.selector) return (false, 0, 0, 0, false);
        success = true;

        // reason -> reason+0x1f is the length of the reason string
        // reason+0x20 -> reason+0x23 is the selector
        // reason+0x24 -> reason+0x43 is pnl
        // reason+0x44 -> reason+0x63 is funding
        // reason+0x64 -> reason+0x83 is netMargin
        // reason+0x84 -> reason+0xa3 is wasLiquidated
        assembly ("memory-safe") {
            pnl := mload(add(reason, 0x24))
            funding := mload(add(reason, 0x44))
            netMargin := mload(add(reason, 0x64))
            wasLiquidated := mload(add(reason, 0x84))
        }
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
