SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := mul_fusion_detect_tb_top
COCOTB_TEST_MODULES := test_mul_fusion_detect
REPO_ROOT := $(abspath ../../..)
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(REPO_ROOT)/rtl/common/o3_pkg.sv $(REPO_ROOT)/rtl/backend/decoder.sv $(REPO_ROOT)/rtl/backend/mul_fusion_detect.sv $(REPO_ROOT)/rtl/backend/rename_stage.sv $(CURDIR)/mul_fusion_detect_tb_top.sv
EXTRA_ARGS += --timing -Wno-fatal --assert
ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-structs
endif
include $(shell cocotb-config --makefiles)/Makefile.sim
