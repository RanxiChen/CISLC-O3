SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := fu_issue_pipeline_tb_top
COCOTB_TEST_MODULES := test_fu_issue_pipeline
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(addprefix $(REPO_ROOT)/,rtl/common/o3_isa_pkg.sv rtl/common/o3_platform_pkg.sv rtl/common/o3_cfg_pkg.sv rtl/common/o3_types_pkg.sv rtl/common/o3_pkg.sv rtl/backend/fu_issue_buffer.sv rtl/backend/mdu_regread.sv rtl/backend/fp_regread.sv rtl/backend/mem_regread.sv) $(CURDIR)/fu_issue_pipeline_tb_top.sv
SIM_BUILD := $(CURDIR)/sim_build/$(if $(filter 1,$(WAVES)),waves,plain)
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
TEST_SEED ?= 1
export TEST_SEED
EXTRA_ARGS += --timing -Wno-fatal --assert
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif
include $(shell cocotb-config --makefiles)/Makefile.sim
