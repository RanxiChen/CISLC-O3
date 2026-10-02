SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := ras_tb_top
COCOTB_TEST_MODULES := test_ras

REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := \
	$(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv \
	$(REPO_ROOT)/rtl/common/o3_isa_pkg.sv \
	$(REPO_ROOT)/rtl/common/o3_types_pkg.sv \
	$(REPO_ROOT)/rtl/frontend/ras.sv \
	$(CURDIR)/ras_tb_top.sv

SIM_BUILD := $(CURDIR)/sim_build/depth$(TEST_DEPTH)
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
TEST_DEPTH ?= 16
TEST_SEED ?= 1
export TEST_SEED

EXTRA_ARGS += --timing -Wno-fatal -GTEST_DEPTH=$(TEST_DEPTH)
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
