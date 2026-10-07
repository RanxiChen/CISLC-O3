SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := icache_tb_top
COCOTB_TEST_MODULES := test_icache
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := \
  $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_types_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_sram_1r1w.sv \
  $(REPO_ROOT)/rtl/common/pmp_checker.sv $(REPO_ROOT)/rtl/common/pma_checker.sv $(REPO_ROOT)/rtl/frontend/itlb.sv $(REPO_ROOT)/rtl/frontend/icache.sv \
  $(CURDIR)/icache_tb_top.sv
SIM_BUILD := $(CURDIR)/sim_build/$(if $(filter 1,$(WAVES)),waves,plain)
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
TEST_SEED ?= 1
export TEST_SEED
EXTRA_ARGS += --timing -Wno-fatal
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif
include $(shell cocotb-config --makefiles)/Makefile.sim
