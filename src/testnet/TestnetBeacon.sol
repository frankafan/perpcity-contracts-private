// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {ITWAPBeacon} from "../interfaces/ITWAPBeacon.sol";
import {UintTWAP} from "../libraries/UintTWAP.sol";
import {MAX_CARDINALITY} from "../utils/Constants.sol";
import {Ownable} from "@solady/src/auth/Ownable.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";

contract TestnetBeacon is ITWAPBeacon, Ownable {
    using UintTWAP for UintTWAP.Observation[MAX_CARDINALITY];
    using SafeCastLib for *;

    uint256 public immutable creationTimestamp;

    uint256 private data;
    uint256 private timestamp;

    UintTWAP.State public twapState;

    constructor(address owner, uint256 initialData, uint32 initialCardinalityNext) {
        _initializeOwner(owner);
        data = initialData;
        timestamp = block.timestamp;

        (twapState.cardinality, twapState.cardinalityNext) =
            twapState.observations.initialize(block.timestamp.toUint32());

        twapState.cardinalityNext = twapState.observations.grow(twapState.cardinalityNext, initialCardinalityNext);

        (twapState.index, twapState.cardinality) = twapState.observations.write(
            twapState.index, block.timestamp.toUint32(), initialData, twapState.cardinality, twapState.cardinalityNext
        );

        creationTimestamp = block.timestamp;
    }

    function getData() external view returns (uint256) {
        return (data);
    }

    function updateData(bytes calldata proof, bytes calldata publicSignals) external onlyOwner {
        data = abi.decode(publicSignals, (uint256));
        timestamp = block.timestamp;

        (twapState.index, twapState.cardinality) = twapState.observations.write(
            twapState.index, block.timestamp.toUint32(), data, twapState.cardinality, twapState.cardinalityNext
        );

        emit DataUpdated(data);
    }

    function increaseCardinalityNext(uint32 cardinalityNext)
        external
        returns (uint32 cardinalityNextOld, uint32 cardinalityNextNew)
    {
        cardinalityNextOld = twapState.cardinalityNext;
        cardinalityNextNew = twapState.observations.grow(cardinalityNextOld, cardinalityNext);
        twapState.cardinalityNext = cardinalityNextNew;
    }

    function getTWAP(uint32 twapSecondsAgo) external view returns (uint256 twapPrice) {
        if (twapSecondsAgo == 0) return data;

        uint32 timeSinceCreation = (block.timestamp - creationTimestamp).toUint32();
        if (timeSinceCreation < twapSecondsAgo) twapSecondsAgo = timeSinceCreation;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapSecondsAgo;
        secondsAgos[1] = 0;
        uint256[] memory priceCumulatives = twapState.observations.observe(
            block.timestamp.toUint32(), secondsAgos, data, twapState.index, twapState.cardinality
        );
        return (priceCumulatives[1] - priceCumulatives[0]) / twapSecondsAgo;
    }
}
