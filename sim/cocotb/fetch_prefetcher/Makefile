SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := prefetch_tb_top
COCOTB_TEST_MODULES := test_prefetch
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/frontend/prefetch_xlate_cache.sv $(REPO_ROOT)/rtl/frontend/fetch_prefetcher.sv $(CURDIR)/prefetch_tb_top.sv
EXTRA_ARGS += --timing -Wno-fatal --assert
include $(shell cocotb-config --makefiles)/Makefile.sim
