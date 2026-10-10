#!/usr/bin/env bash
# Run on a host selected by the live simulation-host policy. Module gates only.
set -uo pipefail
: "${EVIDENCE_DIR:?set an absolute, distinct evidence directory}"
mkdir -p "$EVIDENCE_DIR"
mapfile -t sources < <(python3 -c '
from pathlib import Path
for raw in Path("rtl/rtl.f").read_text().splitlines():
    line=raw.strip()
    if line.endswith(".sv") and line.startswith(("rtl/common/", "rtl/frontend/")):
        print(line)
')
failed=0
verilator --lint-only --timing --assert -Wno-fatal --top-module frontend_ooc_wrapper \
    "${sources[@]}" scripts/vivado/frontend_ooc_wrapper.sv > "$EVIDENCE_DIR/lint.log" 2>&1
rc=$?
printf 'lint\t%s\n' "$rc" > "$EVIDENCE_DIR/status.tsv"
if ((rc)); then failed=1; fi
for name in ifu_f0 ifu_f1 fetch_return_queue fetch_prefetcher icache; do
    make -j4 -C "sim/cocotb/$name" sim TEST_SEED="${TEST_SEED:-1}" \
        EXTRA_ARGS='--timing --assert -Wno-fatal' \
        COCOTB_RESULTS_FILE="$EVIDENCE_DIR/$name.xml" > "$EVIDENCE_DIR/$name.log" 2>&1
    rc=$?
    printf '%s\t%s\n' "$name" "$rc" >> "$EVIDENCE_DIR/status.tsv"
    if ((rc)); then failed=1; fi
done
python3 - "$EVIDENCE_DIR" <<'PY'
import json, sys, xml.etree.ElementTree as ET
from pathlib import Path
root=Path(sys.argv[1]); results={}; failed=False
for name in ("ifu_f0", "ifu_f1", "fetch_return_queue", "fetch_prefetcher", "icache"):
    path=root / (name+".xml")
    if not path.exists():
        results[name]={"missing_xml":True}; failed=True; continue
    cases=ET.parse(path).findall(".//testcase")
    result={"tests":len(cases), "failures":sum(c.find("failure") is not None or c.find("error") is not None for c in cases),
            "skips":sum(c.find("skipped") is not None for c in cases)}
    results[name]=result
    failed |= not cases or result["failures"]>0 or result["skips"]>0
(root/"test-results.json").write_text(json.dumps(results,indent=2)+"\n")
sys.exit(int(failed))
PY
if (($?)); then failed=1; fi
exit "$failed"
