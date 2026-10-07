SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := fpu_fu_tb_top
COCOTB_TEST_MODULES := test_fpu_fu
REPO_ROOT := $(abspath ../../..)
# Use the authoritative manifest, with paths rooted for cocotb's cwd.
RTL_FILES := $(shell sed -n '/^[^\/ +].*\.[sv]*v$$/p' $(REPO_ROOT)/rtl/rtl.f)
VERILOG_SOURCES := $(addprefix $(REPO_ROOT)/,$(RTL_FILES)) $(CURDIR)/fpu_fu_tb_top.sv
EXTRA_ARGS += --timing -Wno-fatal --assert $(REPO_ROOT)/scripts/cvfpu.vlt +incdir+$(REPO_ROOT)/third_party/cvfpu/src/common_cells/include
TEST_SEED ?= 1
export TEST_SEED
include $(shell cocotb-config --makefiles)/Makefile.sim
