SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := dcache_tb_top
COCOTB_TEST_MODULES := test_dcache
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := \
  $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_types_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_sram_1r1w.sv \
  $(REPO_ROOT)/rtl/lsu/dcache.sv \
  $(REPO_ROOT)/sim/cocotb/dcache/dcache_tb_top.sv
SIM_BUILD := $(CURDIR)/sim_build/$(if $(filter 1,$(WAVES)),waves,plain)
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
TEST_SEED ?= 1
export TEST_SEED
EXTRA_ARGS += --timing -Wno-fatal
include $(shell cocotb-config --makefiles)/Makefile.sim
