SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := dcache_tb_top
COCOTB_TEST_MODULES := test_dcache,test_l8a_dcache
REPO_ROOT := $(abspath ../../..)
SETS ?= 64
WAYS ?= 8
MSHRS ?= 4
WBS ?= 2
RFO ?= 1
export SETS WAYS MSHRS WBS RFO
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(wildcard $(REPO_ROOT)/rtl/lsu/dcache*.sv) $(CURDIR)/dcache_tb_top.sv
SIM_BUILD ?= $(CURDIR)/sim_build/s$(SETS)-w$(WAYS)-m$(MSHRS)-b$(WBS)-r$(RFO)
COCOTB_RESULTS_FILE ?= $(CURDIR)/results.xml
TEST_SEED ?= 1
export TEST_SEED
COMPILE_ARGS += --timing --assert -Wno-fatal -GSETS=$(SETS) -GWAYS=$(WAYS) -GMSHRS=$(MSHRS) -GWBS=$(WBS) -GRFO=$(RFO)
include $(shell cocotb-config --makefiles)/Makefile.sim
