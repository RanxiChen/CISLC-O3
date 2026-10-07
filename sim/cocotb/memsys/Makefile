SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := memsys_tb_top
COCOTB_TEST_MODULES := test_memsys
REPO_ROOT := $(abspath ../../..)
MSHRS ?= 1
GEOMETRY ?= pressure
RFO ?= 0
ifeq ($(GEOMETRY),pressure)
SETS := 2
WAYS := 2
WBS := 1
L2_SETS := 2
L2_WAYS := 2
SLOTS := 2
else
SETS := 64
WAYS := 8
WBS := 2
L2_SETS := 512
L2_WAYS := 8
SLOTS := 8
endif
export MSHRS GEOMETRY RFO SETS WAYS WBS L2_SETS L2_WAYS SLOTS
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(wildcard $(REPO_ROOT)/rtl/lsu/dcache*.sv) $(wildcard $(REPO_ROOT)/rtl/memory/l2_*.sv) $(CURDIR)/../dcache/dcache_tb_top.sv $(CURDIR)/../l2_home/l2_home_tb_top.sv $(CURDIR)/memsys_tb_top.sv
SIM_BUILD ?= $(CURDIR)/sim_build/$(GEOMETRY)-m$(MSHRS)-r$(RFO)
COCOTB_RESULTS_FILE ?= $(CURDIR)/results.xml
COMPILE_ARGS += --timing --assert -Wno-fatal -GSETS=$(SETS) -GWAYS=$(WAYS) -GMSHRS=$(MSHRS) -GWBS=$(WBS) -GRFO=$(RFO) -GL2_SETS=$(L2_SETS) -GL2_WAYS=$(L2_WAYS) -GSLOTS=$(SLOTS)
include $(shell cocotb-config --makefiles)/Makefile.sim
