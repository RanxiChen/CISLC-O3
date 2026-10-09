SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := store_queue_tb_top
COCOTB_TEST_MODULES := test_store_queue,test_l8b_store_queue
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := \
  $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_types_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_pkg.sv \
  $(REPO_ROOT)/rtl/backend/store_queue.sv \
  $(CURDIR)/store_queue_tb_top.sv
SIM_BUILD := $(CURDIR)/sim_build/$(if $(filter 1,$(WAVES)),waves,plain)
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
EXTRA_ARGS += --timing -Wno-fatal --assert
export PYTHONPATH := $(REPO_ROOT)/sim/cocotb:$(PYTHONPATH)
include $(shell cocotb-config --makefiles)/Makefile.sim
