SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := branch_recovery_tb_top
COCOTB_TEST_MODULES := test_branch_recovery
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := \
  $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_types_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_pkg.sv \
  $(REPO_ROOT)/rtl/backend/int_execute_unit.sv \
  $(REPO_ROOT)/rtl/backend/alu_pipe.sv \
  $(REPO_ROOT)/rtl/backend/branch_execute_unit.sv \
  $(REPO_ROOT)/rtl/backend/branch_unit.sv \
  $(REPO_ROOT)/rtl/frontend/fetch_buffer.sv \
  $(REPO_ROOT)/rtl/frontend/redirect_arbiter.sv \
  $(CURDIR)/branch_recovery_tb_top.sv
SIM_BUILD := $(CURDIR)/sim_build/$(if $(filter 1,$(WAVES)),waves,plain)
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
TEST_SEED ?= 1
export TEST_SEED
EXTRA_ARGS += --timing -Wno-fatal --assert
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif
include $(shell cocotb-config --makefiles)/Makefile.sim
