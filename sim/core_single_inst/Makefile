VERILATOR ?= verilator

SIM_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT := $(abspath $(SIM_DIR)/../..)

TEST ?= single_addi
TOP ?= o3_core
KANATA ?= 0

BUILD_ROOT := $(SIM_DIR)/build
BUILD_DIR := $(BUILD_ROOT)/$(TEST)
TEST_SRC := $(SIM_DIR)/tests/$(TEST).cpp
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
	$(REPO_ROOT)/rtl/backend/uop_queue.sv \
	$(REPO_ROOT)/rtl/backend/rob.sv \
	$(REPO_ROOT)/rtl/backend/issue_queue.sv \
	$(REPO_ROOT)/rtl/backend/physical_regfile.sv \
	$(REPO_ROOT)/rtl/backend/int_execute_unit.sv \
	$(REPO_ROOT)/rtl/backend/backend.sv \
	$(REPO_ROOT)/rtl/core/o3_core.sv

CPP_SRCS := \
	$(SIM_DIR)/dpi_stubs.cpp

VERILATOR_DEFINES := -DO3_SIM -DO3_SIM_SINGLE_INST_TRACE -DENABLE_RETIRE_INFO

ifeq ($(KANATA),1)
	VERILATOR_DEFINES += -DO3_SIM_KANATA -DO3_SIM_KANATA_LOG_NAME=\"core_single_inst\"
endif

VERILATOR_FLAGS := \
	--cc \
	--exe \
	--build \
	-Wall \
	-Wno-fatal \
	-I$(REPO_ROOT)/tb \
	--top-module $(TOP) \
	--Mdir $(BUILD_DIR) \
	$(VERILATOR_DEFINES)

.PHONY: list build run test clean clean-test

list:
	@echo "Available core single-instruction tests:"
	@find $(SIM_DIR)/tests -maxdepth 1 -name "*.cpp" -printf "  %f\n" | sed 's/\.cpp$$//'

build:
	@if [ ! -f "$(TEST_SRC)" ]; then \
		echo "Missing test source: $(TEST_SRC)"; \
		exit 1; \
	fi
	rm -rf $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)
	cd $(SIM_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) $(TEST_SRC) $(CPP_SRCS) $(RTL_SRCS)

run:
	@if [ ! -x "$(RUN_BIN)" ]; then \
		echo "Missing binary: $(RUN_BIN)"; \
		echo "Run: make build TEST=$(TEST)"; \
		exit 1; \
	fi
	cd $(SIM_DIR) && $(RUN_BIN)

test: build run

clean-test:
	rm -rf $(BUILD_DIR)

clean:
	rm -rf $(BUILD_ROOT)
