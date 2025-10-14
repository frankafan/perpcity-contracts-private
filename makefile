.PHONY: test-halmos test-halmos-usdc
compile:
	solc --standard-json perpcity-input.json > perpcity-output.json
test-halmos:
	FOUNDRY_PROFILE=halmos halmos --contract PerpManagerHalmosTest
