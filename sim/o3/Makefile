VERILATOR ?= verilator

SIM_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT := $(abspath $(SIM_DIR)/../..)
BUILD_DIR ?= $(SIM_DIR)/build
SPIKE_PREFIX ?= $(CONDA_PREFIX)
SPIKE_CFLAGS = $(shell PKG_CONFIG_PATH=$(SPIKE_PREFIX)/lib/pkgconfig pkg-config --cflags riscv-riscv)
SPIKE_LIBS = $(shell PKG_CONFIG_PATH=$(SPIKE_PREFIX)/lib/pkgconfig pkg-config --libs riscv-riscv)
SPIKE_ARGS ?=
SEEDS ?= 1-200
RETIRE_TARGET ?= 3000
SPIKE_OUT ?= $(SIM_DIR)/spike-out
TOP := o3_tandem_top
RUN_BIN := $(BUILD_DIR)/V$(TOP)

VERILATOR_FLAGS := \
	--cc \
	--exe \
	--build \
	-Wno-fatal --assert \
	-f rtl/rtl.f \
	--top-module $(TOP) \
	--Mdir $(BUILD_DIR) \
	-DENABLE_RETIRE_INFO \
	-CFLAGS "-std=c++20 $(SPIKE_CFLAGS)" \
	-LDFLAGS "$(SPIKE_LIBS)"

.PHONY: build run run-smoke run-icache-smoke run-rv64i-instructions run-dcache-data run-dcache-replay run-unified-memory run-l3-branch-dense test clean

build:
	@test -n "$(SPIKE_PREFIX)" && test -f "$(SPIKE_PREFIX)/lib/pkgconfig/riscv-riscv.pc" || { echo 'Activate cislc-o3 with the pinned Spike installed'; exit 1; }
	rm -rf $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)
	cd $(REPO_ROOT) && $(VERILATOR) $(VERILATOR_FLAGS) $(SIM_DIR)/o3_tandem_top.sv $(SIM_DIR)/main.cpp

run: run-smoke

run-smoke: run-icache-smoke

run-icache-smoke:
	@if [ ! -x "$(RUN_BIN)" ]; then \
		echo "Missing binary: $(RUN_BIN)"; \
		echo "Run: make build"; \
		exit 1; \
	fi
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) $(SPIKE_ARGS) --image tests/smoke.hex --reset-pc 0x80000000 \
		--trace icache_smoke.jsonl --max-retires 4 --max-cycles 1000 \
		--require-icache-refill
	cd $(SIM_DIR) && python3 check_trace.py --trace icache_smoke.jsonl \
		--expect tests/icache_smoke.expected.json

run-rv64i-instructions:
	@if [ ! -x "$(RUN_BIN)" ]; then \
		echo "Missing binary: $(RUN_BIN)"; \
		echo "Run: make build"; \
		exit 1; \
	fi
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) $(SPIKE_ARGS) \
		--image tests/rv64i_instructions.hex \
		--reset-pc 0x80000000 \
		--trace rv64i_instructions.jsonl \
		--max-cycles 5000 --max-retires 14
	cd $(SIM_DIR) && python3 check_trace.py \
		--trace rv64i_instructions.jsonl \
		--expect tests/rv64i_instructions.expected.json

run-dcache-data:
	@if [ ! -x "$(RUN_BIN)" ]; then \
		echo "Missing binary: $(RUN_BIN)"; \
		echo "Run: make build"; \
		exit 1; \
	fi
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) $(SPIKE_ARGS) \
		--image tests/dcache_data.hex \
		--reset-pc 0x80000000 \
		--trace dcache_data.jsonl \
		--max-cycles 5000 --max-retires 7
	cd $(SIM_DIR) && python3 check_trace.py \
		--trace dcache_data.jsonl \
		--expect tests/dcache_data.expected.json

run-dcache-replay:
	@if [ ! -x "$(RUN_BIN)" ]; then \
		echo "Missing binary: $(RUN_BIN)"; \
		echo "Run: make build"; \
		exit 1; \
	fi
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) $(SPIKE_ARGS) \
		--image tests/dcache_replay.hex \
		--reset-pc 0x80000000 \
		--trace dcache_replay.jsonl \
		--max-cycles 5000 --max-retires 6 --require-load-replay
	cd $(SIM_DIR) && python3 check_trace.py \
		--trace dcache_replay.jsonl \
		--expect tests/dcache_replay.expected.json

run-unified-memory:
	@if [ ! -x "$(RUN_BIN)" ]; then \
		echo "Missing binary: $(RUN_BIN)"; \
		echo "Run: make build"; \
		exit 1; \
	fi
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) $(SPIKE_ARGS) \
		--image tests/unified_memory.hex \
		--reset-pc 0x10000000 \
		--trace unified_memory.jsonl \
		--max-cycles 5000 --max-retires 18
	cd $(SIM_DIR) && python3 check_trace.py \
		--trace unified_memory.jsonl \
		--expect tests/unified_memory.expected.json

test: build run-smoke

clean:
	rm -rf $(BUILD_DIR) tandem.jsonl icache_smoke.jsonl rv64i_instructions.jsonl dcache_data.jsonl dcache_replay.jsonl unified_memory.jsonl

# Frozen input/oracle: 40 correct BNE, 40 taken BEQ, 40 JAL; 365 retires.
run-l3-branch-dense:
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) $(SPIKE_ARGS) --image tests/l3_branch_dense.hex \
		--reset-pc 0x80000000 --trace l3_branch_dense.jsonl \
		--max-cycles 30000 --max-retires 365 --require-load-replay
	cd $(SIM_DIR) && python3 check_trace.py --trace l3_branch_dense.jsonl \
		--expect tests/l3_branch_dense.expected.json

.PHONY: run-spike-all run-spike-random run-spike-selftest run-spike-act4
run-spike-all:
	$(MAKE) run-smoke run-rv64i-instructions run-dcache-data run-dcache-replay run-l3-branch-dense SPIKE_ARGS=--spike

run-spike-random:
	cd $(SIM_DIR) && env -u O3_INJECT python3 run_spike.py random --sim $(RUN_BIN) --seeds $(SEEDS) --target $(RETIRE_TARGET) --output $(SPIKE_OUT)/random

run-spike-selftest:
	cd $(SIM_DIR) && env -u O3_INJECT python3 run_spike.py selftest --sim $(RUN_BIN) --output $(SPIKE_OUT)/selftest

run-spike-act4:
	$(MAKE) -C $(REPO_ROOT)/verification/act4 run OUT_DIR=$(SPIKE_OUT)/act4
