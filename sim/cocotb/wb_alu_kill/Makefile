SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := wb_alu_kill_tb_top
COCOTB_TEST_MODULES := test_wb_alu_kill
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/common/o3_pkg.sv $(REPO_ROOT)/rtl/backend/int_execute_unit.sv $(REPO_ROOT)/rtl/backend/alu_pipe.sv $(REPO_ROOT)/rtl/backend/writeback_arbiter.sv $(CURDIR)/wb_alu_kill_tb_top.sv
SIM_BUILD := $(CURDIR)/sim_build/plain
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
TEST_SEED ?= 1
export TEST_SEED
export PYTHONPATH := $(REPO_ROOT)/sim/cocotb:$(PYTHONPATH)
EXTRA_ARGS += --timing -Wno-fatal --assert
include $(shell cocotb-config --makefiles)/Makefile.sim
