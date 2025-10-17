HALMOS_OUTPUT_DIR := halmos/out


.PHONY: test-halmos test-halmos-usdc

test-halmos: clean
	mkdir -p $(HALMOS_OUTPUT_DIR)/smt
	@echo "Running Halmos..."
	FOUNDRY_PROFILE=halmos halmos \
		--contract PerpManagerHalmosTest \
		-v \
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
		--solver z3 \
		# --flamegraph \
		# --cache-solver \
		# --ffi \
		# --symbolic-jump \
	> $(HALMOS_OUTPUT_DIR)/halmos_test.log
	@echo "Done."
	make analyze
analyze:
	python halmos/analyze_out.py $(HALMOS_OUTPUT_DIR)/halmos_test.json

clean:
	rm -rf $(HALMOS_OUTPUT_DIR)/*