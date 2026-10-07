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

.PHONY: run-spike-all run-spike-branch-loop run-spike-random run-spike-selftest run-spike-act4
run-spike-all: run-spike-head-ready run-spike-illegal-zero run-spike-platform-ids
	$(MAKE) run-smoke run-rv64i-instructions run-dcache-data run-dcache-replay run-l3-branch-dense SPIKE_ARGS=--spike
	$(MAKE) run-spike-branch-loop run-spike-prf-lane-order

# Twelve static instructions; two loop iterations must retire before tohost.
# Spike supplies the independent dynamic oracle, including any younger lane
# in the mailbox retirement cycle (Q9). Existing fixed checkers stay intact.
run-spike-branch-loop:
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) --spike --image tests/branch_loop.hex \
		--reset-pc 0x80000000 --trace branch_loop.jsonl \
		--tohost-address 0x8010fff8 --max-retires 1000 --max-cycles 5000

run-spike-random:
	cd $(SIM_DIR) && env -u O3_INJECT python3 run_spike.py random --sim $(RUN_BIN) --seeds $(SEEDS) --target $(RETIRE_TARGET) --output $(SPIKE_OUT)/random

run-spike-selftest:
	cd $(SIM_DIR) && env -u O3_INJECT python3 run_spike.py selftest --sim $(RUN_BIN) --output $(SPIKE_OUT)/selftest

run-spike-act4:
	$(MAKE) -C $(REPO_ROOT)/verification/act4 run OUT_DIR=$(SPIKE_OUT)/act4

.PHONY: run-spike-prf-lane-order
run-spike-prf-lane-order:
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) --spike --image tests/prf_lane_order.hex \
		--reset-pc 0x80000000 --trace prf_lane_order.jsonl --max-retires 3 --max-cycles 1000

.PHONY: run-spike-mmode
run-spike-mmode:
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) --spike --image tests/mmode.hex \
		--reset-pc 0x80000000 --trace mmode.jsonl --tohost-address 0x8010fff8 \
		--max-retires 3000 --max-cycles 100000

.PHONY: run-spike-head-ready
run-spike-head-ready:
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) --spike --image tests/ecall_head.hex --trace ecall_head.jsonl --max-retires 1 --max-cycles 1000
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) --spike --image tests/serial_head.hex --trace serial_head.jsonl --max-retires 3 --max-cycles 2000

.PHONY: run-spike-illegal-zero
run-spike-illegal-zero:
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) --spike --image tests/illegal_zero.hex --trace illegal_zero.jsonl --max-retires 1 --max-cycles 1000

.PHONY: run-spike-platform-ids
run-spike-platform-ids:
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) --spike --image tests/platform_ids.hex --trace platform_ids.jsonl --max-retires 3 --max-cycles 1000

# L6 directed only; compiler path is supplied by the Alan environment.
RISCV_GCC ?= riscv64-unknown-elf-gcc
L6_ELF ?= $(BUILD_DIR)/l6_smoke.elf
.PHONY: run-l6-smoke
run-l6-smoke:
	$(RISCV_GCC) -march=rv64im_zicsr_zifencei -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles -static -T$(REPO_ROOT)/verification/riscv-tests/l5/link.ld $(SIM_DIR)/tests/l6_smoke.S -o $(L6_ELF)
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) --spike --image $(L6_ELF) --trace $(BUILD_DIR)/l6_smoke.jsonl --tohost-address 0x801ff000 --max-cycles 20000 --max-retires 2000

# L7a: handwritten program, two groups with identical measured code layout.
# Performance thresholds are markers; correctness/consistency failures fail make.
.PHONY: run-l7-predict
run-l7-predict:
	$(RISCV_GCC) -DGROUP_A -march=rv64im_zicsr -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles -static -T$(SIM_DIR)/tests/l7_predict.ld $(SIM_DIR)/tests/l7_predict.S -o $(BUILD_DIR)/l7_predict_a.elf
	$(RISCV_GCC) -DGROUP_B -march=rv64im_zicsr -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles -static -T$(SIM_DIR)/tests/l7_predict.ld $(SIM_DIR)/tests/l7_predict.S -o $(BUILD_DIR)/l7_predict_b.elf
	python3 $(SIM_DIR)/check_l7_layout.py --a $(BUILD_DIR)/l7_predict_a.elf --b $(BUILD_DIR)/l7_predict_b.elf --output $(BUILD_DIR)/l7_layout.json
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) +L7_CHECK --image $(BUILD_DIR)/l7_predict_a.elf --trace $(BUILD_DIR)/l7_predict_a.jsonl --tohost-address 0x801ff000 --max-cycles 1500000 --max-retires 150000
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) +L7_CHECK --image $(BUILD_DIR)/l7_predict_b.elf --trace $(BUILD_DIR)/l7_predict_b.jsonl --tohost-address 0x801ff000 --max-cycles 1500000 --max-retires 150000
	python3 $(SIM_DIR)/check_l7_predict.py --a $(BUILD_DIR)/l7_predict_a.jsonl --b $(BUILD_DIR)/l7_predict_b.jsonl --layout $(BUILD_DIR)/l7_layout.json --output $(BUILD_DIR)/l7_predict_summary.json

.PHONY: run-l7b-rvc
run-l7b-rvc:
	$(RISCV_GCC) -march=rv64imc_zicsr -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles -static -T$(SIM_DIR)/tests/l7_predict.ld $(SIM_DIR)/tests/l7b_rvc.S -o $(BUILD_DIR)/l7b_rvc.elf
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) +L7_CHECK --image $(BUILD_DIR)/l7b_rvc.elf --trace $(BUILD_DIR)/l7b_rvc.jsonl --tohost-address 0x801ff000 --max-cycles 200000 --max-retires 30000

# L9 current complete F/D RTL: small self-check, no transitional T07A masking.
.PHONY: run-l9-fp
run-l9-fp:
	$(RISCV_GCC) -march=rv64imfdc_zicsr -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles -static -T$(SIM_DIR)/tests/l7_predict.ld $(SIM_DIR)/tests/l9_fp.S -o $(BUILD_DIR)/l9_fp.elf
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) +L7_CHECK --image $(BUILD_DIR)/l9_fp.elf --trace $(BUILD_DIR)/l9_fp.jsonl --tohost-address 0x801ff000 --max-cycles 100000 --max-retires 10000

# Sequential basic gate; retain run-l9-fp as the broader dependency/replay case.
.PHONY: run-l9-fp-smoke
run-l9-fp-smoke:
	$(RISCV_GCC) -march=rv64imfdc_zicsr -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles -static -T$(SIM_DIR)/tests/l7_predict.ld $(SIM_DIR)/tests/l9_fp_smoke.S -o $(BUILD_DIR)/l9_fp_smoke.elf
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) +L7_CHECK --image $(BUILD_DIR)/l9_fp_smoke.elf --trace $(BUILD_DIR)/l9_fp_smoke.jsonl --tohost-address 0x801ff000 --max-cycles 100000 --max-retires 10000

# Integer single-slot replay regression: DIV -> old LD -> dependent SD -> young LD.
.PHONY: run-replay-order
run-replay-order:
	$(RISCV_GCC) -march=rv64im_zicsr -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles -static -T$(SIM_DIR)/tests/l7_predict.ld $(SIM_DIR)/tests/replay-integer.S -o $(BUILD_DIR)/replay-integer.elf
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) +L7_CHECK --image $(BUILD_DIR)/replay-integer.elf --trace $(BUILD_DIR)/replay-integer.jsonl --tohost-address 0x801ff000 --max-cycles 20000 --max-retires 1000

# T08a: Bare M/S/U, delegation, interrupt/WFI/Sstc, counter access and PMP.
.PHONY: run-l10-priv
run-l10-priv:
	$(RISCV_GCC) -march=rv64im_zicsr -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles -static -T$(SIM_DIR)/tests/l7_predict.ld $(SIM_DIR)/tests/l10_priv.S -o $(BUILD_DIR)/l10_priv.elf
	cd $(SIM_DIR) && env -u O3_INJECT $(RUN_BIN) +L7_CHECK --image $(BUILD_DIR)/l10_priv.elf --trace $(BUILD_DIR)/l10_priv.jsonl --tohost-address 0x801ff000 --max-cycles 100000 --max-retires 10000
