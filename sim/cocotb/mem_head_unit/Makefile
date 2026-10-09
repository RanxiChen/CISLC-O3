SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := mem_head_unit_tb_top
COCOTB_TEST_MODULES := test_mem_head_unit
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/common/o3_pkg.sv $(REPO_ROOT)/rtl/backend/mem_head_unit.sv $(CURDIR)/mem_head_unit_tb_top.sv
TEST_SEED ?= 1
export TEST_SEED
EXTRA_ARGS += --timing -Wno-fatal --assert
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif
include $(shell cocotb-config --makefiles)/Makefile.sim

export PYTHONPATH := $(REPO_ROOT)/sim/cocotb:$(PYTHONPATH)
