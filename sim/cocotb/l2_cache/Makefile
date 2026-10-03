SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := l2_cache_tb_top
COCOTB_TEST_MODULES := test_l2_cache
REPO_ROOT := $(abspath ../../..)
RTL_SOURCES := $(shell rg '^rtl/' $(REPO_ROOT)/rtl/rtl.f)
VERILOG_SOURCES := $(addprefix $(REPO_ROOT)/,$(RTL_SOURCES)) \
  $(REPO_ROOT)/sim/o3/o3_tandem_top.sv \
  $(REPO_ROOT)/sim/cocotb/l2_cache/l2_cache_tb_top.sv
SIM_BUILD := $(CURDIR)/sim_build/$(if $(filter 1,$(WAVES)),waves,plain)
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
TEST_SEED ?= 1
export TEST_SEED
EXTRA_ARGS += --timing -Wno-fatal -DENABLE_RETIRE_INFO
include $(shell cocotb-config --makefiles)/Makefile.sim
