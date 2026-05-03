VERILATOR ?= verilator

SIM_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT := $(abspath $(SIM_DIR)/../..)

TEST ?= frontend_basic
TOP ?= frontend

BUILD_ROOT := $(SIM_DIR)/build
BUILD_DIR := $(BUILD_ROOT)/$(TEST)
TEST_SRC := $(SIM_DIR)/tests/$(TEST).cpp
RUN_BIN := $(BUILD_DIR)/V$(TOP)

RTL_SRCS := \
	$(REPO_ROOT)/rtl/common/o3_pkg.sv \
	$(REPO_ROOT)/rtl/frontend/ftq.sv \
	$(REPO_ROOT)/rtl/frontend/bpu.sv \
	$(REPO_ROOT)/rtl/frontend/ifu.sv \
	$(REPO_ROOT)/rtl/common/lfsr.sv \
	$(REPO_ROOT)/rtl/common/o3_sram.sv \
	$(REPO_ROOT)/rtl/frontend/icache.sv \
	$(REPO_ROOT)/rtl/frontend/fetch_buffer.sv \
	$(REPO_ROOT)/rtl/frontend/frontend.sv

VERILATOR_DEFINES := \
	-DO3_SIM

VERILATOR_FLAGS := \
	--cc \
	--exe \
	--build \
	-Wall \
	-Wno-fatal \
	--top-module $(TOP) \
	--Mdir $(BUILD_DIR) \
	$(VERILATOR_DEFINES)

.PHONY: list build run test clean clean-test

list:
	@echo "Available frontend tests:"
	@find $(SIM_DIR)/tests -maxdepth 1 -name "*.cpp" -printf "  %f\n" | sed 's/\.cpp$$//'

build:
	@if [ ! -f "$(TEST_SRC)" ]; then \
		echo "Missing test source: $(TEST_SRC)"; \
		exit 1; \
	fi
	rm -rf $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)
	cd $(SIM_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) $(TEST_SRC) $(RTL_SRCS)

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
