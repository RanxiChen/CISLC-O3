SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := mdu_tb_top
COCOTB_TEST_MODULES := test_mdu
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/common/o3_pkg.sv $(REPO_ROOT)/rtl/backend/signed_mul65x65.sv $(REPO_ROOT)/rtl/backend/unsigned_radix4_divider.sv $(REPO_ROOT)/rtl/backend/fu_completion_fifo.sv $(REPO_ROOT)/rtl/backend/mul_execute_unit.sv $(REPO_ROOT)/rtl/backend/div_execute_unit.sv $(CURDIR)/mdu_tb_top.sv
EXTRA_ARGS += --timing -Wno-fatal --assert
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif
DIV ?= 0
EXTRA_ARGS += -GDIV_UNIT=$(DIV)
SIM_BUILD := sim_build_$(DIV)
include $(shell cocotb-config --makefiles)/Makefile.sim
