SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := ifu_f0_tb_top
COCOTB_TEST_MODULES := test_ifu_f0
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := \
  $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv \
  $(REPO_ROOT)/rtl/common/o3_types_pkg.sv \
  $(CURDIR)/ifu_f0_reference.sv $(REPO_ROOT)/rtl/frontend/rvc_expander.sv $(REPO_ROOT)/rtl/frontend/ifu_f0.sv \
  $(CURDIR)/ifu_f0_tb_top.sv
SIM_BUILD := $(CURDIR)/sim_build/$(if $(filter 1,$(WAVES)),waves,plain)
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
TEST_SEED ?= 1
export TEST_SEED
EXTRA_ARGS += --timing --assert -Wno-fatal
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif
include $(shell cocotb-config --makefiles)/Makefile.sim
