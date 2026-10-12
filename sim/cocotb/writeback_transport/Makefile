SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := writeback_transport_tb_top
COCOTB_TEST_MODULES := test_writeback_transport
REPO_ROOT := $(abspath ../../..)
SOURCES ?= 11
PORTS ?= 2
DEPTH ?= 3
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/common/o3_pkg.sv $(REPO_ROOT)/rtl/backend/writeback_transport.sv $(CURDIR)/writeback_transport_tb_top.sv
TEST_SEED ?= 105
export TEST_SEED
COMPILE_ARGS += --timing --assert -Wno-fatal -GSOURCES=$(SOURCES) -GPORTS=$(PORTS) -GDEPTH=$(DEPTH)
SIM_BUILD ?= $(CURDIR)/sim_build/s$(SOURCES)-p$(PORTS)-d$(DEPTH)
include $(shell cocotb-config --makefiles)/Makefile.sim
