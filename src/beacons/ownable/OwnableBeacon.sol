// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {ITimeWeightedAvg} from "../../interfaces/ITimeWeightedAvg.sol";
import {IBeacon} from "../../interfaces/beacons/IBeacon.sol";
import {TimeWeightedAvg} from "../../libraries/TimeWeightedAvg.sol";
import {Ownable} from "@solady/src/auth/Ownable.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";

/// @title OwnableBeacon
/// @notice A beacon that is owned by an address and can be updated to any value by the owner
contract OwnableBeacon is IBeacon, ITimeWeightedAvg, Ownable {
    using TimeWeightedAvg for TimeWeightedAvg.State;
    using SafeCastLib for *;

    /* STORAGE */

    /// @notice The state used to track and calculate a time weighted average of `indexX96`
    TimeWeightedAvg.State public twAvgState;

    /// @notice The beacon's data
    /// @dev This is scaled by 2^96
    uint256 private indexX96;

    /* CONSTRUCTOR */

    /// @notice Instantiates the beacon
    /// @param owner The owner of the beacon
    /// @param initialIndexX96 The initial data of the beacon scaled by 2^96
    /// @param initialCardinalityCap The initial cardinality cap set for the beacon's time weighted average
    constructor(address owner, uint256 initialIndexX96, uint16 initialCardinalityCap) {
        _initializeOwner(owner);
        indexX96 = initialIndexX96;

        // initialize twavg state, grow list to specified cardinality, and write first observation
        twAvgState.initialize(block.timestamp.toUint32());
        twAvgState.increaseCardinalityCap(initialCardinalityCap);
        twAvgState.write(block.timestamp.toUint32(), initialIndexX96);
    }

    /* FUNCTIONS */

    /// @inheritdoc IBeacon
    function data() external view returns (uint256 index) {
        return indexX96;
    }

    /// @inheritdoc IBeacon
    /// @dev only the owner can update data. Encoded public signals should be the encided uint256 value of the new index
    function updateData(bytes calldata, bytes calldata encodedPublicSignals) external onlyOwner {
        indexX96 = abi.decode(encodedPublicSignals, (uint256));
        twAvgState.write(block.timestamp.toUint32(), indexX96);
        emit DataUpdated(indexX96);
    }

    /// @inheritdoc ITimeWeightedAvg
    function increaseCardinalityCap(uint16 newCap) external {
        twAvgState.increaseCardinalityCap(newCap);
    }

    /// @inheritdoc ITimeWeightedAvg
    function timeWeightedAvg(uint32 twapSecondsAgo) external view returns (uint256 twAvgIndexX96) {
        return twAvgState.timeWeightedAvg(twapSecondsAgo, block.timestamp.toUint32(), indexX96);
    }
}
