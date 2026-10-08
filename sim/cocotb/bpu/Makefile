SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := bpu_tb_top
COCOTB_TEST_MODULES := test_bpu
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_sram_1r1w.sv  \
  $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_types_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_pkg.sv \
  $(REPO_ROOT)/rtl/frontend/ftq.sv \
  $(REPO_ROOT)/rtl/frontend/ubtb.sv \
  $(REPO_ROOT)/rtl/frontend/main_btb.sv \
  $(REPO_ROOT)/rtl/frontend/tage.sv \
  $(REPO_ROOT)/rtl/frontend/branch_history.sv \
  $(REPO_ROOT)/rtl/frontend/ras.sv \
  $(REPO_ROOT)/rtl/frontend/bpu_slow_check.sv \
  $(REPO_ROOT)/rtl/frontend/loop_predictor.sv $(REPO_ROOT)/rtl/frontend/bpu.sv \
  $(CURDIR)/bpu_tb_top.sv
SIM_BUILD := $(CURDIR)/sim_build/$(COCOTB_TOPLEVEL)/$(if $(filter 1,$(WAVES)),waves,plain)
COCOTB_RESULTS_FILE := $(CURDIR)/$(COCOTB_TOPLEVEL)-results.xml
TEST_SEED ?= 1
export TEST_SEED
EXTRA_ARGS += --timing -Wno-fatal --assert
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif
include $(shell cocotb-config --makefiles)/Makefile.sim
