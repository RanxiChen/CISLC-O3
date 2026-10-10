SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := ifu_decode_queue_tb_top
COCOTB_TEST_MODULES := test_ifu_decode_queue
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv \
 $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv \
 $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/frontend/ifu_decode_queue.sv \
 $(CURDIR)/ifu_decode_queue_tb_top.sv
SIM_BUILD := $(CURDIR)/sim_build/queue
EXTRA_ARGS += --timing --assert -Wno-fatal
TEST_SEED ?= 1
export TEST_SEED
include $(shell cocotb-config --makefiles)/Makefile.sim
