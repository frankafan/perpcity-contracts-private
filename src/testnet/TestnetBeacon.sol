// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IBeacon} from "../interfaces/IBeacon.sol";
import {ITimeWeightedAvg} from "../interfaces/ITimeWeightedAvg.sol";
import {TimeWeightedAvg} from "../libraries/TimeWeightedAvg.sol";
import {Ownable} from "@solady/src/auth/Ownable.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";

contract TestnetBeacon is IBeacon, ITimeWeightedAvg, Ownable {
    using TimeWeightedAvg for TimeWeightedAvg.State;
    using SafeCastLib for *;

    uint256 public immutable creationTimestamp;

    uint216 private priceX96;

    TimeWeightedAvg.State public twaState;

    event DataUpdated(uint256 priceX96);

    constructor(address owner, uint256 initialData, uint32 initialCardinalityNext) {
        _initializeOwner(owner);

        twaState.initialize(block.timestamp.toUint32());

        twaState.grow(initialCardinalityNext);

        twaState.write(block.timestamp.toUint32(), initialData.toUint216());

        creationTimestamp = block.timestamp;
    }

    function getData() external view returns (uint256) {
        return priceX96;
    }

    function updateData(bytes calldata proof, bytes calldata publicSignals) external onlyOwner {
        priceX96 = abi.decode(publicSignals, (uint256)).toUint216();

        twaState.write(block.timestamp.toUint32(), priceX96);

        emit DataUpdated(priceX96);
    }

    function increaseCardinalityNext(uint32 cardinalityNext) external {
        twaState.grow(cardinalityNext);
    }

    function getTimeWeightedAvg(uint32 twapSecondsAgo) external view returns (uint256 twapPrice) {
        uint32 timeSinceLastObservation = (block.timestamp - twaState.getOldestObservationTimestamp()).toUint32();
        if (twapSecondsAgo > timeSinceLastObservation) twapSecondsAgo = timeSinceLastObservation;

        if (twapSecondsAgo == 0) return priceX96;

        uint32 timeSinceCreation = (block.timestamp - creationTimestamp).toUint32();
        if (timeSinceCreation < twapSecondsAgo) twapSecondsAgo = timeSinceCreation;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapSecondsAgo;
        secondsAgos[1] = 0;
        uint216[] memory priceCumulatives = twaState.observe(block.timestamp.toUint32(), secondsAgos, priceX96);
        return (priceCumulatives[1] - priceCumulatives[0]) / twapSecondsAgo;
    }
}
