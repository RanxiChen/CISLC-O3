SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := platform_pma_tb_top
COCOTB_TEST_MODULES := test_platform_pma
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/common/pma_checker.sv $(CURDIR)/platform_pma_tb_top.sv
EXTRA_ARGS += --timing -Wno-fatal --assert
include $(shell cocotb-config --makefiles)/Makefile.sim
