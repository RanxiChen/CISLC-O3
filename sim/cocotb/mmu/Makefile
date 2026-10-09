SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := mmu_tb_top
COCOTB_TEST_MODULES := test_mmu
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/common/o3_pkg.sv $(REPO_ROOT)/rtl/frontend/itlb.sv $(REPO_ROOT)/rtl/lsu/dtlb.sv $(REPO_ROOT)/rtl/lsu/walk_cache.sv $(REPO_ROOT)/rtl/lsu/ptw.sv $(REPO_ROOT)/rtl/lsu/pte_ad_updater.sv $(CURDIR)/mmu_tb_top.sv
TEST_SEED ?= 1
export TEST_SEED
EXTRA_ARGS += --timing -Wno-fatal --assert
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif
include $(shell cocotb-config --makefiles)/Makefile.sim
