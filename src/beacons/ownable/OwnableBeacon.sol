// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {IBeacon} from "../../interfaces/IBeacon.sol";
import {ITimeWeightedAvg} from "../../interfaces/ITimeWeightedAvg.sol";
import {TimeWeightedAvg} from "../../libraries/TimeWeightedAvg.sol";
import {Ownable} from "@solady/src/auth/Ownable.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";

contract OwnableBeacon is IBeacon, ITimeWeightedAvg, Ownable {
    using TimeWeightedAvg for TimeWeightedAvg.State;
    using SafeCastLib for *;

    uint256 public immutable creationTimestamp;
    TimeWeightedAvg.State public twapState;

    uint216 private indexX96;

    constructor(address owner, uint256 initialIndexX96, uint32 initialCardinalityNext) {
        _initializeOwner(owner);
        indexX96 = initialIndexX96.toUint216();

        twapState.initialize(block.timestamp.toUint32());
        twapState.grow(initialCardinalityNext);
        twapState.write(block.timestamp.toUint32(), indexX96);

        creationTimestamp = block.timestamp;
    }

    function getData() external view returns (uint256) {
        return indexX96;
    }

    function updateData(bytes calldata proof, bytes calldata publicSignals) external onlyOwner {
        indexX96 = abi.decode(publicSignals, (uint256)).toUint216();

        twapState.write(block.timestamp.toUint32(), indexX96);

        emit DataUpdated(indexX96);
    }

    function increaseCardinalityNext(uint32 cardinalityNext) external {
        twapState.grow(cardinalityNext);
    }

    function getTimeWeightedAvg(uint32 twapSecondsAgo) external view returns (uint256 twapPrice) {
        uint32 timeSinceLastObservation = (block.timestamp - twapState.getOldestObservationTimestamp()).toUint32();
        if (twapSecondsAgo > timeSinceLastObservation) twapSecondsAgo = timeSinceLastObservation;

        if (twapSecondsAgo == 0) return indexX96;

        uint32 timeSinceCreation = (block.timestamp - creationTimestamp).toUint32();
        if (timeSinceCreation < twapSecondsAgo) twapSecondsAgo = timeSinceCreation;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapSecondsAgo;
        secondsAgos[1] = 0;
        uint216[] memory priceCumulatives = twapState.observe(block.timestamp.toUint32(), secondsAgos, indexX96);
        return (priceCumulatives[1] - priceCumulatives[0]) / twapSecondsAgo;
    }
}
