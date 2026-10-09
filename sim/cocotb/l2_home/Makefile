SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := l2_home_tb_top
COCOTB_TEST_MODULES := test_l2_home
REPO_ROOT := $(abspath ../../..)
SETS ?= 2
WAYS ?= 2
SLOTS ?= 2
export SETS WAYS SLOTS
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_platform_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(wildcard $(REPO_ROOT)/rtl/memory/l2_*.sv) $(CURDIR)/l2_home_tb_top.sv
SIM_BUILD ?= $(CURDIR)/sim_build/s$(SETS)-w$(WAYS)-n$(SLOTS)
COCOTB_RESULTS_FILE ?= $(CURDIR)/results.xml
COMPILE_ARGS += --timing --assert -Wno-fatal -GSETS=$(SETS) -GWAYS=$(WAYS) -GSLOTS=$(SLOTS)
DIRECTED := gets_miss_and_none_hit,getm_miss_and_none_hit,shared_upgrade_acke,clean_put,dirty_put,read_miss_and_hit,read_unique_down_latest,replacement_unique_inv_dirty_axi,same_set_serialization,axi_read_error_not_installed
ifeq ($(SETS)-$(WAYS)-$(SLOTS),2-2-2)
COCOTB_TESTCASE ?= $(DIRECTED),random_seed_51,random_seed_52
else
COCOTB_TESTCASE ?= $(DIRECTED)
endif
include $(shell cocotb-config --makefiles)/Makefile.sim
