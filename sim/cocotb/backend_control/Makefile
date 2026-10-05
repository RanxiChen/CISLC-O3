SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := backend_control_tb_top
COCOTB_TEST_MODULES := test_backend_control
REPO_ROOT := $(abspath ../../..)
RTL_SOURCES := $(shell rg '^rtl/' $(REPO_ROOT)/rtl/rtl.f)
VERILOG_SOURCES := $(addprefix $(REPO_ROOT)/,$(RTL_SOURCES)) \
  $(CURDIR)/backend_control_tb_top.sv
SIM_BUILD := $(CURDIR)/sim_build/$(if $(filter 1,$(WAVES)),waves,plain)
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
TEST_SEED ?= 1
export TEST_SEED
export PYTHONPATH := $(REPO_ROOT)/sim/cocotb:$(PYTHONPATH)
EXTRA_ARGS += --timing -Wno-fatal --assert -DENABLE_RETIRE_INFO
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif
include $(shell cocotb-config --makefiles)/Makefile.sim
