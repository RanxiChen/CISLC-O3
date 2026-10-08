#!/usr/bin/env bash
# Execute only on the selected simulation host after live host preflight.
# EVIDENCE_DIR must be distinct per final SHA. Every goal keeps its own log/XML.
set -uo pipefail
: "${EVIDENCE_DIR:?set EVIDENCE_DIR on the verified simulation host}"
mkdir -p "$EVIDENCE_DIR"
failed=0
run() {
 local label=$1; shift
 "$@" >"$EVIDENCE_DIR/$label.log" 2>&1
 local rc=$?
 printf '%s\t%s\n' "$label" "$rc" | tee -a "$EVIDENCE_DIR/status.tsv"
 if ((rc)); then failed=1; tail -25 "$EVIDENCE_DIR/$label.log"; fi
}
# Full repository cocotb default suite, including all backend/memory modules.
for makefile in sim/cocotb/*/Makefile; do
 module=${makefile%/Makefile};name=${module##*/}
 run "$name-1" make -C "$module" sim TEST_SEED=1 COCOTB_RESULTS_FILE="$EVIDENCE_DIR/$name-1.xml"
done
# Frozen randomized predictor/frontend seeds beyond the default seed.
for seed in 7 29; do
 for name in fetch_return_queue tage main_btb bpu loop_predictor fetch_prefetcher icache csr_file mmu ubtb ras redirect_arbiter bpu_slow_check frontend_sync_ctrl pmp_checker; do
  run "$name-$seed" make -C "sim/cocotb/$name" sim TEST_SEED="$seed" COCOTB_RESULTS_FILE="$EVIDENCE_DIR/$name-$seed.xml"
 done
done
run ftq-metadata make -C sim/cocotb/bpu sim COCOTB_TOPLEVEL=ftq_training_tb_top COCOTB_TEST_MODULES=test_ftq SIM_BUILD=sim_build/ftq COCOTB_RESULTS_FILE="$EVIDENCE_DIR/ftq-metadata.xml"
run sram-poison make -C sim/cocotb/o3_sram_1r1w sim ALLOW_COLLISION=1 COCOTB_TEST_MODULES=test_collision SIM_BUILD=sim_build/poison COCOTB_RESULTS_FILE="$EVIDENCE_DIR/sram-poison.xml"
# Negative gate: an assertion abort must be observed, not treated as a pass XML.
make -C sim/cocotb/o3_sram_1r1w sim ALLOW_COLLISION=0 COCOTB_TEST_MODULES=test_forbidden_collision SIM_BUILD=sim_build/negative COCOTB_RESULTS_FILE="$EVIDENCE_DIR/sram-negative.xml" >"$EVIDENCE_DIR/sram-negative.log" 2>&1
rc=$?
if ((rc==0)) || ! rg -q 'o3_sram_1r1w: same-address read/write' "$EVIDENCE_DIR/sram-negative.log"; then failed=1;printf 'sram-negative\t1\n' >>"$EVIDENCE_DIR/status.tsv";else printf 'sram-negative\t0\n' >>"$EVIDENCE_DIR/status.tsv";fi
# Required serialized memory configurations, using distinct builds.
run dcache-n2-m4 make -C sim/cocotb/dcache sim MSHRS=4 COCOTB_TEST_MODULES=test_l8b_dcache COCOTB_TESTCASE= COCOTB_RESULTS_FILE="$EVIDENCE_DIR/dcache-n2-m4.xml"
run dcache-m1 make -C sim/cocotb/dcache sim MSHRS=1 COCOTB_RESULTS_FILE="$EVIDENCE_DIR/dcache-m1.xml"
run dcache-n2-m1 make -C sim/cocotb/dcache sim MSHRS=1 COCOTB_TEST_MODULES=test_l8b_dcache COCOTB_TESTCASE= COCOTB_RESULTS_FILE="$EVIDENCE_DIR/dcache-n2-m1.xml"
run pte-cache make -C sim/cocotb/mmu -f Makefile.pte sim SIM_BUILD=sim_build/pte COCOTB_RESULTS_FILE="$EVIDENCE_DIR/pte-cache.xml"
exit "$failed"
