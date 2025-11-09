LOOP ?= 2
TIMESTAMP := $(shell date +%m%d_%H%M%S)
HALMOS_OUTPUT_DIR := halmos/out-$(TIMESTAMP)


.PHONY: test-halmos test-halmos-usdc

compile:
	FOUNDRY_PROFILE=halmos forge build

test-halmos:
	mkdir -p $(HALMOS_OUTPUT_DIR)/smt
	FOUNDRY_PROFILE=halmos halmos \
		--contract PerpManagerHalmosTest \
		-v \
		--loop $(LOOP) \
		--statistics \
		--json-output $(HALMOS_OUTPUT_DIR)/halmos_test.json \
		--coverage-output $(HALMOS_OUTPUT_DIR)/coverage.log \
		--dump-smt-queries \
		--dump-smt-directory $(HALMOS_OUTPUT_DIR)/smt \
		--trace-memory \
		--print-mem \
		--print-states \
		--print-success-states \
		--print-failed-states \
		--print-blocked-states \
		--print-setup-states \
		--print-full-model \
		--profile-instructions \
		--no-status \
		--solver z3 | tee $(HALMOS_OUTPUT_DIR)/halmos_test.log
		# --print-steps
		# --flamegraph \
		# --cache-solver \
		# --ffi \
		# --symbolic-jump \
	@echo "Output directory: $(HALMOS_OUTPUT_DIR)"
	make analyze DIR=$(HALMOS_OUTPUT_DIR)

test-halmos-timed:
	@echo "Output directory: $(HALMOS_OUTPUT_DIR)"
	@/usr/bin/time -p make test-halmos 2>&1 | tee $(HALMOS_OUTPUT_DIR)/time.log

analyze:
	python halmos/analyze_out.py $(DIR)/halmos_test.json

build-dockerfile:
	cd halmos && docker build -t perpcityhalmos -f dockerfile .

run-container:
	docker run -it -v .:/workspace --entrypoint=/bin/bash perpcityhalmos

test-concrete:
	forge test --match-contract IncreaseCardinalityTest -vv

coverage:
	# apt-get install lcov
	genhtml coverage.log  --ignore-errors unmapped --output-directory report 

step-halmos:
	mkdir -p $(HALMOS_OUTPUT_DIR)/smt
	FOUNDRY_PROFILE=halmos halmos \
		--contract PerpManagerHalmosTest \
		-v \
		--loop $(LOOP) \
		--statistics \
		--json-output $(HALMOS_OUTPUT_DIR)/halmos_test.json \
		--coverage-output $(HALMOS_OUTPUT_DIR)/coverage.log \
		--dump-smt-queries \
		--dump-smt-directory $(HALMOS_OUTPUT_DIR)/smt \
		--no-status \
		--print-steps \
		--solver z3 | tee $(HALMOS_OUTPUT_DIR)/halmos_test.log
		# --flamegraph \
		# --cache-solver \
		# --ffi \
		# --symbolic-jump \
	@echo "Output directory: $(HALMOS_OUTPUT_DIR)"
	make analyze DIR=$(HALMOS_OUTPUT_DIR)
