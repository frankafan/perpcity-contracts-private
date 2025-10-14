/// @notice Create symbolic perp parameters
function _createSymbolicPerpParams() internal returns (IPerpManager.CreatePerpParams memory) {
    uint160 startingSqrtPriceX96 = uint160(svm.createUint(160, "startingSqrtPriceX96"));
    address beacon = svm.createAddress("beacon");

    // Assume valid sqrt price range
    // MIN_SQRT_RATIO = 4295128739, MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342
    vm.assume(startingSqrtPriceX96 >= 4295128739);
    vm.assume(startingSqrtPriceX96 <= type(uint160).max);
    vm.assume(beacon != address(0));

    return IPerpManager.CreatePerpParams({startingSqrtPriceX96: startingSqrtPriceX96, beacon: beacon});
}

/// @notice Create symbolic maker position parameters
function _createSymbolicMakerParams() internal returns (IPerpManager.OpenMakerPositionParams memory) {
    uint256 margin = svm.createUint256("maker.margin");
    uint128 liq = uint128(svm.createUint(128, "maker.liquidity"));
    int24 tickLower = int24(int256(svm.createUint(24, "maker.tickLower")));
    int24 tickUpper = int24(int256(svm.createUint(24, "maker.tickUpper")));
    uint128 maxAmt0 = uint128(svm.createUint(128, "maker.maxAmt0In"));
    uint128 maxAmt1 = uint128(svm.createUint(128, "maker.maxAmt1In"));

    // Assumptions
    vm.assume(margin > 0);
    vm.assume(liq > 0);
    vm.assume(tickLower < tickUpper);
    vm.assume(maxAmt0 > 0);
    vm.assume(maxAmt1 > 0);

    return
        IPerpManager.OpenMakerPositionParams({
            margin: margin,
            liquidity: liq,
            tickLower: tickLower,
            tickUpper: tickUpper,
            maxAmt0In: maxAmt0,
            maxAmt1In: maxAmt1
        });
}

/// @notice Create symbolic taker position parameters
function _createSymbolicTakerParams() internal returns (IPerpManager.OpenTakerPositionParams memory) {
    bool isLong = svm.createBool("taker.isLong");
    uint256 margin = svm.createUint256("taker.margin");
    uint256 levX96 = svm.createUint256("taker.levX96");
    uint128 limit = uint128(svm.createUint(128, "taker.limit"));

    // Assumptions
    vm.assume(margin > 0);
    vm.assume(levX96 > 0);
    vm.assume(limit > 0);

    return
        IPerpManager.OpenTakerPositionParams({
            isLong: isLong,
            margin: margin,
            levX96: levX96,
            unspecifiedAmountLimit: limit
        });
}
