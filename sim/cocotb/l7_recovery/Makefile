SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := l7_recovery_tb_top
COCOTB_TEST_MODULES := test_l7_recovery
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/common/o3_pkg.sv $(REPO_ROOT)/rtl/frontend/ifu_f1.sv $(REPO_ROOT)/rtl/frontend/redirect_arbiter.sv $(REPO_ROOT)/rtl/frontend/fetch_buffer.sv $(REPO_ROOT)/rtl/frontend/fetch_return_queue.sv $(REPO_ROOT)/rtl/system/hpm_counters.sv $(REPO_ROOT)/rtl/system/csr_file.sv $(CURDIR)/l7_recovery_tb_top.sv
SIM_BUILD := $(CURDIR)/sim_build
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
EXTRA_ARGS += --timing -Wno-fatal --assert
include $(shell cocotb-config --makefiles)/Makefile.sim
