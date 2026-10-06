SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := rvc_expander
COCOTB_TEST_MODULES := test_rvc_expander
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/frontend/rvc_expander.sv
EXTRA_ARGS += --timing -Wno-fatal --assert
include $(shell cocotb-config --makefiles)/Makefile.sim
