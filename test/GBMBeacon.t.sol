// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {GBMBeacon} from "../src/beacons/gbm/GBMBeacon.sol";
import {IVerifierWrapper} from "../src/interfaces/beacons/IVerifierWrapper.sol";
import {UINT_Q96} from "../src/libraries/Constants.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

contract MockVerifierWrapper is IVerifierWrapper {
    function verify(
        bytes calldata, // proof
        bytes calldata publicSignals
    ) external pure override returns (bool success, uint256 data) {
        return (true, abi.decode(publicSignals, (uint256)));
    }

    function verifier() external view returns (address) {
        return address(0);
    }
}

contract GBMBeaconTest is Test {
    GBMBeacon public beacon;
    address public owner = makeAddr("owner");

    uint256 public initialIndexX96 = 7922816251426433759354395033600; // 100 * 2^96
    uint16 public initialCardinalityCap = 100;
    uint256 public thresholdX96 = 39614081257132168796771975168; // 0.5 * 2^96
    uint256 public sigmaBase = 0.001e18;
    uint256 public positiveRate = 0.5e18;

    uint256 public updateCount = 100;

    function setUp() public {
        beacon = new GBMBeacon(
            new MockVerifierWrapper(),
            owner,
            initialIndexX96,
            initialCardinalityCap,
            thresholdX96,
            sigmaBase,
            positiveRate
        );
    }

    function test_updateData() public {
        vm.startPrank(owner);

        for (uint256 i = 0; i < updateCount; i++) {
            // update beacon with random data between 0.25 and 1 (scaled by 2^96)
            // this is biased upwards
            uint256 randomData = vm.randomUint(UINT_Q96 / 4, UINT_Q96);
            // uint256 randomData = vm.randomUint(0, 3 * UINT_Q96 / 4);
            beacon.updateData(bytes(""), abi.encode(randomData));

            // log data and twap at timestamp
            console2.log("TIMESTAMP: ", block.timestamp);

            uint256 data = beacon.data();
            uint256 scaledData = data * 1e6 / UINT_Q96;
            console2.log("MARK: %6e", scaledData);

            // uint256 twap = beacon.getTimeWeightedAvg(600);
            // uint256 scaledTwap = twap * 1e6 / UINT_Q96;
            // console2.log("MARK TWAP: %6e", scaledTwap);

            // skip 3 minutes
            skip(180);
        }

        vm.stopPrank();
    }
}
