SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := o3_sram_1r1w
COCOTB_TEST_MODULES := test_o3_sram_1r1w
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_sram_1r1w.sv
SIM_BUILD := $(CURDIR)/sim_build/$(if $(filter 1,$(WAVES)),waves,plain)
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
TEST_SEED ?= 1
export TEST_SEED
ALLOW_COLLISION ?= 0
export ALLOW_COLLISION
EXTRA_ARGS += --timing -Wno-fatal --assert -GALLOW_COLLISION=$(ALLOW_COLLISION)
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif
include $(shell cocotb-config --makefiles)/Makefile.sim
