VERILATOR ?= verilator

SIM_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT := $(abspath $(SIM_DIR)/../..)
BUILD_DIR := $(SIM_DIR)/build
TOP := o3_tandem_top
RUN_BIN := $(BUILD_DIR)/V$(TOP)

VERILATOR_FLAGS := \
	--cc \
	--exe \
	--build \
	-Wno-fatal \
	-f rtl/rtl.f \
	--top-module $(TOP) \
	--Mdir $(BUILD_DIR) \
	-DENABLE_RETIRE_INFO

.PHONY: build run run-smoke run-rv64i-instructions run-unified-memory test clean

build:
	rm -rf $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)
	cd $(REPO_ROOT) && $(VERILATOR) $(VERILATOR_FLAGS) $(SIM_DIR)/o3_tandem_top.sv $(SIM_DIR)/main.cpp

run: run-smoke

run-smoke:
	@if [ ! -x "$(RUN_BIN)" ]; then \
		echo "Missing binary: $(RUN_BIN)"; \
		echo "Run: make build"; \
		exit 1; \
	fi
	cd $(SIM_DIR) && $(RUN_BIN) --image tests/smoke.hex --trace tandem.jsonl \
		--max-retires 4 --max-cycles 1000
	cd $(SIM_DIR) && python3 check_trace.py --trace tandem.jsonl --expect tests/smoke.expected.json

run-rv64i-instructions:
	@if [ ! -x "$(RUN_BIN)" ]; then \
		echo "Missing binary: $(RUN_BIN)"; \
		echo "Run: make build"; \
		exit 1; \
	fi
	cd $(SIM_DIR) && $(RUN_BIN) \
		--image tests/rv64i_instructions.hex \
		--trace rv64i_instructions.jsonl \
		--max-cycles 5000 --max-retires 14
	cd $(SIM_DIR) && python3 check_trace.py \
		--trace rv64i_instructions.jsonl \
		--expect tests/rv64i_instructions.expected.json

run-unified-memory:
	@if [ ! -x "$(RUN_BIN)" ]; then \
		echo "Missing binary: $(RUN_BIN)"; \
		echo "Run: make build"; \
		exit 1; \
	fi
	cd $(SIM_DIR) && $(RUN_BIN) \
		--image tests/unified_memory.hex \
		--reset-pc 0x10000000 \
		--trace unified_memory.jsonl \
		--max-cycles 5000 --max-retires 18
	cd $(SIM_DIR) && python3 check_trace.py \
		--trace unified_memory.jsonl \
		--expect tests/unified_memory.expected.json

test: build run-smoke

clean:
	rm -rf $(BUILD_DIR) tandem.jsonl rv64i_instructions.jsonl unified_memory.jsonl
