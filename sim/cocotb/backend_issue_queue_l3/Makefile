SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := backend_issue_queue_tb_top
COCOTB_TEST_MODULES := test_backend_issue_queue_l3
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/common/o3_pkg.sv $(REPO_ROOT)/rtl/backend/backend_issue_queue.sv $(CURDIR)/backend_issue_queue_tb_top.sv
KIND ?= 0
SIM_BUILD := $(CURDIR)/sim_build/$(KIND)/$(if $(filter 1,$(WAVES)),waves,plain)
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
TEST_SEED ?= 1
export TEST_SEED
export PYTHONPATH := $(REPO_ROOT)/sim/cocotb:$(PYTHONPATH)
COMPILE_ARGS += -GKIND=$(KIND)
EXTRA_ARGS += --timing -Wno-fatal --assert
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif
include $(shell cocotb-config --makefiles)/Makefile.sim
