SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := register_storage_tb_top
COCOTB_TEST_MODULES := test_register_storage
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/common/o3_pkg.sv $(REPO_ROOT)/rtl/backend/physical_regfile.sv $(REPO_ROOT)/rtl/backend/preg_ready_table.sv $(CURDIR)/register_storage_tb_top.sv
PRF_FPGA ?= 1
ifneq ($(strip $(INT_READS)),)
EXTRA_ARGS += -GIR=$(INT_READS)
endif
ifneq ($(strip $(INT_WRITES)),)
EXTRA_ARGS += -GIW=$(INT_WRITES)
endif
EXTRA_ARGS += --timing -Wno-fatal --assert
ifeq ($(PRF_FPGA),1)
EXTRA_ARGS += -DFPGA_TARGET
endif
include $(shell cocotb-config --makefiles)/Makefile.sim
