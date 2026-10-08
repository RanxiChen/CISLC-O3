SIM ?= verilator
TOPLEVEL_LANG := verilog
COCOTB_TOPLEVEL := dcache_tb_top
MSHRS ?= 4
COCOTB_TEST_MODULES := test_dcache,test_l8a_dcache,test_l8a_probe_ps,test_l8a_internal_pmp
ifeq ($(MSHRS),1)
COCOTB_TEST_MODULES := $(COCOTB_TEST_MODULES),test_l8a_single_mshr
COCOTB_TESTCASE ?= empty_line_recall_pipeline,word_banks_refill_store_probe_and_hit_under_miss,dirty_capacity_victim_is_written_back_before_refill,miss_install_and_replay,dual_different_bank_hit,same_bank_different_set_replay,same_line_merge_one_get,drain_hit_e_ps_to_m,drain_shared_upgrade_acke,drain_miss_getm,inv_m_dirty_response,down_m_dirty_response,ptw_read_miss_and_hit,pte_ad_compare_success_and_mismatch,refill_error_install_err_keeps_i,pa_high_bits_access_fault,clean_victim_put_without_data,wb_line_replay_until_ack,probe_waits_for_grant_install,refill_snapshot_replay,s0_store_word_conflict,cancellation_keeps_plru_and_mshr,wb_capacity_full_wait_contract,probe_waits_for_ps_write,single_mshr_full_waits_on_mshr_free,committed_drain_authorized_at_sta_ptw_ad_still_check_pmp
endif
REPO_ROOT := $(abspath ../../..)
SETS ?= 64
WAYS ?= 8
WBS ?= 2
RFO ?= 1
export SETS WAYS MSHRS WBS RFO
VERILOG_SOURCES := $(REPO_ROOT)/rtl/common/o3_isa_pkg.sv $(REPO_ROOT)/rtl/common/o3_cfg_pkg.sv $(REPO_ROOT)/rtl/common/o3_types_pkg.sv $(wildcard $(REPO_ROOT)/rtl/lsu/dcache*.sv) $(REPO_ROOT)/rtl/lsu/lrsc_reservation.sv $(CURDIR)/dcache_tb_top.sv
SIM_BUILD ?= $(CURDIR)/sim_build/s$(SETS)-w$(WAYS)-m$(MSHRS)-b$(WBS)-r$(RFO)
COCOTB_RESULTS_FILE ?= $(CURDIR)/results.xml
TEST_SEED ?= 1
export TEST_SEED
COMPILE_ARGS += --timing --assert -Wno-fatal -GSETS=$(SETS) -GWAYS=$(WAYS) -GMSHRS=$(MSHRS) -GWBS=$(WBS) -GRFO=$(RFO)
include $(shell cocotb-config --makefiles)/Makefile.sim
