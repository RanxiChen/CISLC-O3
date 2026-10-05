SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := frontend_sync_ctrl_tb_top
COCOTB_TEST_MODULES := test_frontend_sync_ctrl
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/common/o3_pkg.sv $(REPO_ROOT)/rtl/frontend/frontend_sync_ctrl.sv $(CURDIR)/frontend_sync_ctrl_tb_top.sv
TEST_SEED ?= 1
export TEST_SEED
EXTRA_ARGS += --timing -Wno-fatal --assert
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif
include $(shell cocotb-config --makefiles)/Makefile.sim
