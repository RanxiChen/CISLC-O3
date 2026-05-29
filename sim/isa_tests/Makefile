VERILATOR ?= verilator

SIM_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT := $(abspath $(SIM_DIR)/../..)

TEST ?= isa_addi
TOP ?= o3_core

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
	$(REPO_ROOT)/rtl/backend/branch_issue_queue.sv \
	$(REPO_ROOT)/rtl/backend/physical_regfile.sv \
	$(REPO_ROOT)/rtl/backend/int_execute_unit.sv \
	$(REPO_ROOT)/rtl/backend/branch_execute_unit.sv \
	$(REPO_ROOT)/rtl/backend/backend.sv \
	$(REPO_ROOT)/rtl/core/o3_core.sv

CPP_SRCS := \
	$(SIM_DIR)/isa_harness.cpp \
	$(REPO_ROOT)/sim/core_three_alu/dpi_stubs.cpp

VERILATOR_DEFINES := -DO3_SIM -DENABLE_RETIRE_INFO

VERILATOR_FLAGS := \
	--cc \
	--exe \
	--build \
	-Wall \
	-Wno-fatal \
	-Wno-VARHIDDEN \
	-Wno-WIDTH \
	-I$(REPO_ROOT)/tb \
	--top-module $(TOP) \
	--Mdir $(BUILD_DIR) \
	$(VERILATOR_DEFINES) \
	-CFLAGS -std=c++20 \
	-CFLAGS -I$(SIM_DIR)

.PHONY: list build run test clean clean-test

list:
	@echo "Available tests:"
	@ls $(SIM_DIR)/tests/*.cpp 2>/dev/null | sed 's|.*/||; s|\.cpp$$||' | sort

build: $(BUILD_DIR)/V$(TOP)

$(BUILD_DIR)/V$(TOP): $(TEST_SRC) $(CPP_SRCS) $(RTL_SRCS)
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) $(TEST_SRC) $(CPP_SRCS) $(RTL_SRCS)

run: build
	$(RUN_BIN)

test: build run

clean-test:
	rm -rf $(BUILD_ROOT)/$(TEST)

clean:
	rm -rf $(BUILD_ROOT)
