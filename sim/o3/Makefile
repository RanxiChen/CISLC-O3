VERILATOR ?= verilator

SIM_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT := $(abspath $(SIM_DIR)/../..)
BUILD_DIR := $(SIM_DIR)/build
TOP := o3_tandem_top
RUN_BIN := $(BUILD_DIR)/V$(TOP)

RTL_SRCS := \
	$(REPO_ROOT)/rtl/common/o3_pkg.sv \
	$(REPO_ROOT)/rtl/common/lfsr.sv \
	$(REPO_ROOT)/rtl/common/o3_sram.sv \
	$(REPO_ROOT)/rtl/frontend/ftq.sv \
	$(REPO_ROOT)/rtl/frontend/bpu.sv \
	$(REPO_ROOT)/rtl/frontend/ifu.sv \
	$(REPO_ROOT)/rtl/frontend/icache.sv \
	$(REPO_ROOT)/rtl/frontend/fetch_buffer.sv \
	$(REPO_ROOT)/rtl/frontend/frontend.sv \
	$(REPO_ROOT)/rtl/backend/decoder.sv \
	$(REPO_ROOT)/rtl/backend/free_list.sv \
	$(REPO_ROOT)/rtl/backend/rename_map_table.sv \
	$(REPO_ROOT)/rtl/backend/branch_checkpoint_file.sv \
	$(REPO_ROOT)/rtl/backend/uop_queue.sv \
	$(REPO_ROOT)/rtl/backend/rename_stage.sv \
	$(REPO_ROOT)/rtl/backend/rename_dispatch_queue.sv \
	$(REPO_ROOT)/rtl/backend/dispatch_stage.sv \
	$(REPO_ROOT)/rtl/backend/backend_issue_queue.sv \
	$(REPO_ROOT)/rtl/backend/load_queue.sv \
	$(REPO_ROOT)/rtl/backend/store_queue.sv \
	$(REPO_ROOT)/rtl/backend/physical_regfile.sv \
	$(REPO_ROOT)/rtl/backend/int_execute_unit.sv \
	$(REPO_ROOT)/rtl/backend/mul_execute_unit.sv \
	$(REPO_ROOT)/rtl/backend/div_execute_unit.sv \
	$(REPO_ROOT)/rtl/backend/branch_execute_unit.sv \
	$(REPO_ROOT)/rtl/backend/writeback_arbiter.sv \
	$(REPO_ROOT)/rtl/memory/simple_data_sram.sv \
	$(REPO_ROOT)/rtl/backend/load_store_unit.sv \
	$(REPO_ROOT)/rtl/backend/rob.sv \
	$(REPO_ROOT)/rtl/backend/backend.sv \
	$(REPO_ROOT)/rtl/core/o3_core.sv \
	$(SIM_DIR)/o3_tandem_top.sv

VERILATOR_FLAGS := \
	--cc \
	--exe \
	--build \
	-Wall \
	-Wno-fatal \
	--top-module $(TOP) \
	--Mdir $(BUILD_DIR) \
	-DENABLE_RETIRE_INFO

.PHONY: build run run-smoke run-rv64i-instructions test clean

build:
	rm -rf $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)
	cd $(SIM_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) $(SIM_DIR)/main.cpp $(RTL_SRCS)

run: run-smoke

run-smoke:
	@if [ ! -x "$(RUN_BIN)" ]; then \
		echo "Missing binary: $(RUN_BIN)"; \
		echo "Run: make build"; \
		exit 1; \
	fi
	cd $(SIM_DIR) && $(RUN_BIN) --image tests/smoke.hex --trace tandem.jsonl --max-retires 4

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

test: build run-smoke run-rv64i-instructions

clean:
	rm -rf $(BUILD_DIR) tandem.jsonl rv64i_instructions.jsonl
