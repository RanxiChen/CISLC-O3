SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := sd_dma_bridge_tb_top
COCOTB_TEST_MODULES := test_sd_dma_bridge
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/platform/sd_dma_bridge.sv $(REPO_ROOT)/rtl/memory/dma_line_adapter.sv $(CURDIR)/sd_dma_bridge_tb_top.sv
COMPILE_ARGS += --timing --assert -Wno-fatal
include $(shell cocotb-config --makefiles)/Makefile.sim
