#!/usr/bin/env python3
"""Check stable architectural fields in a CISLC-O3 Tandem JSONL trace."""

import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace", required=True)
    parser.add_argument("--expect", required=True)
    args = parser.parse_args()

    trace_records = []
    for line in Path(args.trace).read_text(encoding="utf-8").splitlines():
        record = json.loads(line)
        if record.get("type") == "retire":
            trace_records.append(record)

    expected_records = json.loads(Path(args.expect).read_text(encoding="utf-8"))
    if len(trace_records) != len(expected_records):
        raise SystemExit(
            f"TRACE_CHECK_FAIL retire_count actual={len(trace_records)} "
            f"expected={len(expected_records)}"
        )

    stable_fields = ("pc", "instruction", "rd", "rd_write")
    for index, (actual, expected) in enumerate(zip(trace_records, expected_records)):
        for field in stable_fields:
            if actual[field] != expected[field]:
                raise SystemExit(
                    f"TRACE_CHECK_FAIL order={index} field={field} "
                    f"actual={actual[field]} expected={expected[field]}"
                )
        if expected["rd_write"] and actual["rd_wdata"] != expected["rd_wdata"]:
            raise SystemExit(
                f"TRACE_CHECK_FAIL order={index} field=rd_wdata "
                f"actual={actual['rd_wdata']} expected={expected['rd_wdata']}"
            )

    print(f"RV64I_INSTRUCTION_TRACE_PASS retires={len(trace_records)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
