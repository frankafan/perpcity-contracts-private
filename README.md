# perp.city [![Foundry][foundry-badge]][foundry] [![License: GPL][license-badge]][license]

[foundry]: https://getfoundry.sh/
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg
[license]: https://opensource.org/licenses/GPL-3.0
[license-badge]: https://img.shields.io/badge/License-GNU%20GPL-blue

[perp.city](https://perp.city/) allows permissionless perpetual swaps on anything.

## Quick Start

Ensure you have `pnpm` and `foundry` installed

```sh
pnpm install
```

## Build

```sh
forge build
```
or
```sh
pnpm build
```
or

## Run Tests

```sh
forge test
```
or
```sh
pnpm test
```

## Scripts

1. set SENDER & related envs
2. run `cast wallet import devKey --interactive` to set private key for given `SENDER_ADDRESS`
3. run scripts in package.json

## License

This project is licensed under GPL-3.0.
