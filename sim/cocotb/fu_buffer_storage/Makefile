SIM ?= verilator
export TEST_SEED ?= 105
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := fu_buffer_storage_tb_top
COCOTB_TEST_MODULES := test_fu_buffer_storage
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/common/o3_pkg.sv $(REPO_ROOT)/rtl/backend/fu_issue_buffer.sv $(CURDIR)/fu_buffer_storage_tb_top.sv
EXTRA_ARGS += --timing -Wno-fatal --assert
SIM_BUILD := $(CURDIR)/sim_build
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
include $(shell cocotb-config --makefiles)/Makefile.sim
