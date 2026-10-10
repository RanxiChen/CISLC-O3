#!/usr/bin/env bash
# Caller must first reread the shared simulation host policy and select/preflight
# the prescribed host. This gate runs there, never selects a host itself.
set -uo pipefail
: "${EVIDENCE_DIR:?set an absolute distinct evidence directory}"
mkdir -p "$EVIDENCE_DIR"
bash scripts/run-frontend-structural-checks.sh
failed=$?
names=(fetch_buffer tage bpu bpu_slow_check ftq redirect_arbiter loop_predictor main_btb)
for name in "${names[@]}"; do
    make -j4 -C "sim/cocotb/$name" sim TEST_SEED="${TEST_SEED:-1}" \
        EXTRA_ARGS='--timing --assert -Wno-fatal' \
        COCOTB_RESULTS_FILE="$EVIDENCE_DIR/$name.xml" > "$EVIDENCE_DIR/$name.log" 2>&1
    rc=$?
    printf '%s\t%s\n' "$name" "$rc" >> "$EVIDENCE_DIR/status.tsv"
    if ((rc)); then failed=1; fi
done
make -j4 -C sim/cocotb/fetch_buffer -f Makefile.payload sim \
    EXTRA_ARGS='--timing --assert -Wno-fatal' \
    COCOTB_RESULTS_FILE="$EVIDENCE_DIR/fetch_buffer_payload.xml" > "$EVIDENCE_DIR/fetch_buffer_payload.log" 2>&1
rc=$?
printf 'fetch_buffer_payload\t%s\n' "$rc" >> "$EVIDENCE_DIR/status.tsv"
if ((rc)); then failed=1; fi
python3 - "$EVIDENCE_DIR" <<'PY'
import json, sys, xml.etree.ElementTree as ET
from pathlib import Path
root=Path(sys.argv[1]); results={}; failed=False
for path in sorted(root.glob("*.xml")):
    cases=ET.parse(path).findall(".//testcase")
    result={"tests":len(cases), "failures":sum(c.find("failure") is not None or c.find("error") is not None for c in cases),
            "skips":sum(c.find("skipped") is not None for c in cases)}
    results[path.stem]=result
    failed |= not cases or result["failures"]>0 or result["skips"]>0
required={"ifu_f0", "ifu_f1", "fetch_return_queue", "fetch_prefetcher", "icache",
          "fetch_buffer", "fetch_buffer_payload", "tage", "bpu", "bpu_slow_check", "ftq", "redirect_arbiter", "loop_predictor", "main_btb"}
missing=required-set(results)
(root/"test-results.json").write_text(json.dumps({"suites":results,"missing":sorted(missing)},indent=2)+"\n")
sys.exit(int(failed or bool(missing)))
PY
if (($?)); then failed=1; fi
exit "$failed"
