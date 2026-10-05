SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := jalr_tb_top
COCOTB_TEST_MODULES := test_jalr
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/common/o3_pkg.sv $(REPO_ROOT)/rtl/backend/branch_execute_unit.sv $(REPO_ROOT)/rtl/backend/branch_unit.sv $(CURDIR)/jalr_tb_top.sv
EXTRA_ARGS += --timing -Wno-fatal --assert
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif
include $(shell cocotb-config --makefiles)/Makefile.sim
