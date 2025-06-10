# Perpetual Protocol High Level Design

## Simple Actions

There are 6 main actions for traders to take:

1. Open maker position
2. Close maker position
3. Open taker long position
4. Close taker long position
5. Open taker short position
6. Close taker short position

## Fees

Uniswap pools charge fees on the token being swapped in, not the token being swapped out.

Depending on whether the swap is part of a long or short open or close, the token being swapped in could be the USD accounting token or the PERP accounting token.

This is problematic because LPs receive these fees, meaning their dynamic position size would be influenced by the type of token they collect. To solve this, we only charge fees when the swap is USD in and PERP out.

In other words:

- Longs are charged when opening a position
- Shorts are charged when closing a position

This is implemented through `PerpHook.sol`, which allows the swap caller (always `Perp.sol`) to set the fee. The hook also ensures that the caller of any hook action can only be `Perp.sol`.

## Funding

The implementation of continuous funding is inspired by perp v2's block-based funding implementation:

Fundings are settled whenever a trade happens, no matter long or short. The formula is pretty much the same, with only `Funding Interval` slightly modified:

```
Funding Rate = (Premium / Index Price) * Δtime / 1 day
```

Since it's calculated on every trade, `Δtime` is the time difference between two trades. Usually, `Δtime` is measured in seconds, and 1 day is `60 * 60 * 24 = 86400` seconds.

Thus, `Δtime / 1 day` here expresses the same idea as the `Funding Interval` in the Periodic Funding equation: normalize the time difference/period to 1 day.

If we adopt this design in the blockchain's venue, on Ethereum specifically, the time should be measured with `block.timestamp`, and fundings are settled for each new timestamp/new block.

This is the rationale behind the Block-based Funding Payment of Perp v2.

Upon each new trade, a new funding rate is recorded for the time since the last trade.

### References

- [Block-based Funding Payment on Perp v2](https://blog.perp.fi/block-based-funding-payment-on-perp-v2-35527094635e)
- [How Block-based Funding Payment is Implemented on Perp v2](https://blog.perp.fi/how-block-based-funding-payment-is-implemented-on-perp-v2-20cfd5057384)