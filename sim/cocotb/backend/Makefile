SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := o3_tandem_top
COCOTB_TEST_MODULES := test_backend
REPO_ROOT := $(abspath ../../..)
# Use all sources from the authority, including the L9 pinned CVFPU.
RTL_SOURCES := $(shell sed -n '/^[^\/ +].*\.[sv]*v$$/p' $(REPO_ROOT)/rtl/rtl.f)
VERILOG_SOURCES := $(addprefix $(REPO_ROOT)/,$(RTL_SOURCES)) \
  $(REPO_ROOT)/sim/o3/o3_tandem_top.sv
SIM_BUILD := $(CURDIR)/sim_build/$(if $(filter 1,$(WAVES)),waves,plain)
COCOTB_RESULTS_FILE := $(CURDIR)/results.xml
TEST_SEED ?= 1
export TEST_SEED
EXTRA_ARGS += --timing -Wno-fatal --assert -DENABLE_RETIRE_INFO $(REPO_ROOT)/scripts/cvfpu.vlt +incdir+$(REPO_ROOT)/third_party/cvfpu/src/common_cells/include +incdir+$(REPO_ROOT)
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif
include $(shell cocotb-config --makefiles)/Makefile.sim
