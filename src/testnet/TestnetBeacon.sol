// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { ITWAPBeacon } from "../interfaces/ITWAPBeacon.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { UintTWAP } from "../libraries/UintTWAP.sol";
import { MAX_CARDINALITY } from "../utils/Constants.sol";

contract TestnetBeacon is ITWAPBeacon, Ownable {
    using UintTWAP for UintTWAP.Observation[MAX_CARDINALITY];

    uint256 private data;
    uint256 private timestamp;

    UintTWAP.State public twapState;

    event DataUpdated(uint256 data);

    constructor(address owner, uint256 initialData, uint32 initialCardinalityNext) Ownable(owner) {
        (twapState.cardinality, twapState.cardinalityNext) = twapState.observations.initialize(uint32(block.timestamp));

        twapState.cardinalityNext = twapState.observations.grow(twapState.cardinalityNext, initialCardinalityNext);

        (twapState.index, twapState.cardinality) = twapState.observations.write(
            twapState.index, uint32(block.timestamp), initialData, twapState.cardinality, twapState.cardinalityNext
        );
    }

    function getData() external view returns (uint256, uint256) {
        return (data, timestamp);
    }

    function updateData(bytes memory proof, bytes memory publicSignals) external onlyOwner {
        data = abi.decode(publicSignals, (uint256));
        timestamp = block.timestamp;

        (twapState.index, twapState.cardinality) = twapState.observations.write(
            twapState.index, uint32(block.timestamp), data, twapState.cardinality, twapState.cardinalityNext
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
        if (twapSecondsAgo == 0) {
            return data;
        }

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapSecondsAgo;
        secondsAgos[1] = 0;
        uint256[] memory priceCumulatives = twapState.observations.observe(
            uint32(block.timestamp), secondsAgos, data, twapState.index, twapState.cardinality
        );
        return (priceCumulatives[1] - priceCumulatives[0]) / twapSecondsAgo;
    }
}
