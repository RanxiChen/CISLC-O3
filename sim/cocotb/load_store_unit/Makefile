SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := load_store_unit_tb_top
COCOTB_TEST_MODULES := test_load_store_unit,test_l8b_load_store_unit
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := \
  $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_types_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_pkg.sv \
  $(REPO_ROOT)/rtl/lsu/dtlb.sv \
  $(REPO_ROOT)/rtl/backend/load_store_unit.sv \
  $(CURDIR)/load_store_unit_tb_top.sv
SIM_BUILD := $(CURDIR)/sim_build/$(if $(filter 1,$(WAVES)),waves,plain)
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
EXTRA_ARGS += --timing -Wno-fatal --assert
export PYTHONPATH := $(REPO_ROOT)/sim/cocotb:$(PYTHONPATH)
include $(shell cocotb-config --makefiles)/Makefile.sim
