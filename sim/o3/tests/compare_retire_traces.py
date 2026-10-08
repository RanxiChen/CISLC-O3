#!/usr/bin/env python3
"""Align retirement/trap events for diagnosis; this does not accept differences."""
import argparse
from collections import Counter
from difflib import SequenceMatcher
import hashlib
import json
from pathlib import Path


def read_trace(path):
    events = []
    headers = 0
    for line_no, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get('type') == 'header':
            headers += 1
            continue
        if row.get('type') not in ('retire', 'trap'):
            raise ValueError(f'{path}:{line_no}: unexpected event type')
        for field in ('pc', 'instruction', 'order', 'cycle'):
            if field not in row:
                raise ValueError(f'{path}:{line_no}: missing {field}')
        events.append({'event_index': len(events), 'line': line_no, **row})
    return events, headers


def key(row):
    # Include trap identity, so a trap cannot align to a normal retirement at its PC.
    return (row['type'], int(row['pc'], 16), int(row['instruction'], 16),
            row.get('exc_cause') if row['type'] == 'trap' else None,
            row.get('exc_tval') if row['type'] == 'trap' else None)


def compare(left_path, right_path):
    left, lh = read_trace(left_path)
    right, rh = read_trace(right_path)
    lk, rk = [key(x) for x in left], [key(x) for x in right]
    first = next((i for i in range(min(len(lk), len(rk))) if lk[i] != rk[i]),
                 min(len(lk), len(rk)) if len(lk) != len(rk) else None)
    alignment = []
    for op, i, end_i, j, end_j in SequenceMatcher(None, lk, rk, autojunk=False).get_opcodes():
        block = dict(op=op, left_range=[i, end_i], right_range=[j, end_j])
        if op == 'equal':
            block['pairs'] = [[x, y] for x, y in zip(range(i, end_i), range(j, end_j))]
        else:
            block['left_events'] = left[i:end_i]
            block['right_events'] = right[j:end_j]
        alignment.append(block)
    return dict(
        purpose='diagnosis only; no acceptance decision',
        left=dict(path=str(left_path), sha256=hashlib.sha256(left_path.read_bytes()).hexdigest(),
                  headers_skipped=lh, counts=dict(Counter(x['type'] for x in left))),
        right=dict(path=str(right_path), sha256=hashlib.sha256(right_path.read_bytes()).hexdigest(),
                   headers_skipped=rh, counts=dict(Counter(x['type'] for x in right))),
        first_stream_divergence=None if first is None else dict(
            index=first, left=left[first] if first < len(left) else None,
            right=right[first] if first < len(right) else None),
        alignment=alignment)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('left', type=Path)
    parser.add_argument('right', type=Path)
    args = parser.parse_args()
    print(json.dumps(compare(args.left, args.right), indent=2))
