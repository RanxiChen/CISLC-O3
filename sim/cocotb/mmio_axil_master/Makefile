SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := mmio_axil_master_tb_top
COCOTB_TEST_MODULES := test_mmio_axil_master
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/memory/mmio_axil_master.sv $(CURDIR)/mmio_axil_master_tb_top.sv
COMPILE_ARGS += --timing --assert -Wno-fatal
include $(shell cocotb-config --makefiles)/Makefile.sim
