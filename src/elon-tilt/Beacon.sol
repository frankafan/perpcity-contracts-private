// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { IBeacon } from "../interfaces/IBeacon.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IHalo2Verifier } from "../interfaces/IHalo2Verifier.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { IVaultCore } from "../interfaces/IVaultCore.sol";

contract Beacon is IBeacon, Initializable, UUPSUpgradeable, OwnableUpgradeable {
    uint256 constant ORDER = uint256(0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001);

    uint256 private data;
    uint256 private dataTimestamp;
    IHalo2Verifier public verifier;
    mapping(bytes proof => bool isUsed) public usedProofs;
    IERC20 public usdc;
    uint256 private fee; // fee charged in USDC per getData()
    IVaultCore public vault;

    event DataUpdated(uint256 data);

    error ProofAlreadyUsed();
    error InvalidProof();
    error ErrorDequantizing();
    error OldData();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address verifierAddress,
        address usdcAddress,
        address vaultAddress,
        uint256 initialData,
        address initialOwner
    )
        public
        initializer
    {
        __UUPSUpgradeable_init();
        __Ownable_init(initialOwner);

        verifier = IHalo2Verifier(verifierAddress);
        usdc = IERC20(usdcAddress);
        vault = IVaultCore(vaultAddress);
        data = initialData;
        dataTimestamp = block.timestamp;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner { }

    function setFee(uint256 newFee) external onlyOwner {
        fee = newFee;
    }

    function getFee() external view returns (uint256) {
        return fee;
    }

    function updateData(bytes calldata proof, uint256[] calldata instances) external {
        if (usedProofs[proof]) revert ProofAlreadyUsed();
        if (!verifier.verifyProof(proof, instances)) revert InvalidProof();

        uint256 len = instances.length;

        // dequantize data (2nd to last element), 6 decimals to represent price in USDC
        int256 newData = _dequantize(instances[len - 2], 6, 13);
        // dequantize timestamp (last element)
        int256 newTimestamp = _dequantize(instances[len - 1], 0, 0);

        if (newData > 0 && newTimestamp > 0) {
            data = uint256(newData);
            if (uint256(newTimestamp) <= dataTimestamp) revert OldData();
            dataTimestamp = uint256(newTimestamp);
        } else {
            revert ErrorDequantizing();
        }

        usedProofs[proof] = true;
        emit DataUpdated(data);
    }

    function getData() external returns (uint256) {
        usdc.transferFrom(msg.sender, address(this), fee);
        usdc.approve(address(vault), fee);
        vault.depositRevenue(fee);
        return data;
    }

    function getDataTimestamp() external view returns (uint256) {
        return dataTimestamp;
    }

    function getVault() external view returns (address) {
        return address(vault);
    }

    function _dequantize(
        uint256 instance,
        uint256 decimals,
        uint256 scales
    )
        internal
        pure
        returns (int256 rescaledInstance)
    {
        int256 x;
        bool neg;
        if (instance > uint128(type(int128).max)) {
            x = int256(ORDER - instance);
            neg = true;
        } else {
            x = int256(instance);
        }
        uint256 output = Math.mulDiv(uint256(x), 10 ** decimals, 1 << scales);
        if (mulmod(uint256(x), 10 ** decimals, 1 << scales) * 2 >= (1 << scales)) {
            output += 1;
        }

        return neg ? -int256(output) : int256(output);
    }
}
