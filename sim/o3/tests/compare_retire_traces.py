#!/usr/bin/env python3
"""Compare the user-approved spec 12 prefix; exempt only a validated tohost tail."""
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


def number(value):
    return int(value, 0) if isinstance(value, str) else int(value)


def key(row):
    # A trap never aligns to a normal retirement at its PC.
    return (row['type'], number(row['pc']), number(row['instruction']),
            number(row['exc_cause']) if row['type'] == 'trap' else None,
            number(row['exc_tval']) if row['type'] == 'trap' else None)


def cutoff(events, tohost_address, require_tohost=False):
    for index, row in enumerate(events):
        if (row['type'] == 'retire' and row.get('mem_kind') == 'store'
                and number(row.get('mem_addr', 0)) == tohost_address
                and number(row.get('mem_size', 0)) == 8
                and number(row.get('mem_data', 0)) == 1):
            tail = events[index + 1:]
            # The terminal self-jump immediately follows this 4-byte SD.
            terminal_pc = number(row['pc']) + 4
            for later in tail:
                if not (later['type'] == 'retire'
                        and number(later['cycle']) == number(row['cycle'])
                        and number(later['slot']) > number(row['slot'])
                        and number(later['pc']) == terminal_pc
                        and number(later['instruction']) == 0x0000006f
                        and not later.get('rd_write', False)
                        and later.get('mem_kind', 'none') == 'none'):
                    raise ValueError(f'non-exempt event after successful tohost: {later}')
            return events[:index + 1], tail, row
    if require_tohost:
        raise ValueError('missing successful tohost SD')
    # Fixed-retirement golden targets have no tohost; their full stream is strict.
    return events, [], None


def describe(path, events, headers, prefix, tail, store):
    return dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                headers_skipped=headers, counts=dict(Counter(x['type'] for x in events)),
                prefix_events=len(prefix), prefix_counts=dict(Counter(x['type'] for x in prefix)),
                exempt_tail_events=len(tail), exempt_tail=tail, cutoff_store=store)


def compare(left_path, right_path=None, tohost_address=0x801ff000, require_tohost=False):
    left, lh = read_trace(left_path)
    lp, lt, ls = cutoff(left, tohost_address, require_tohost)
    result = dict(rule='user-approved spec 12 retirement prefix interpretation',
                  left=describe(left_path, left, lh, lp, lt, ls))
    if right_path is None:
        return dict(**result, passed=True, purpose='single-trace tail validation and counts only')
    right, rh = read_trace(right_path)
    rp, rt, rs = cutoff(right, tohost_address, require_tohost)
    lk, rk = [key(x) for x in lp], [key(x) for x in rp]
    first = next((i for i in range(min(len(lk), len(rk))) if lk[i] != rk[i]),
                 min(len(lk), len(rk)) if len(lk) != len(rk) else None)
    alignment = []
    for op, i, end_i, j, end_j in SequenceMatcher(None, lk, rk, autojunk=False).get_opcodes():
        block = dict(op=op, left_range=[i, end_i], right_range=[j, end_j])
        if op == 'equal':
            block['pairs'] = [[x, y] for x, y in zip(range(i, end_i), range(j, end_j))]
        else:
            block['left_events'] = lp[i:end_i]
            block['right_events'] = rp[j:end_j]
        alignment.append(block)
    return dict(**result,
        right=describe(right_path, right, rh, rp, rt, rs),
        passed=first is None and bool(ls) == bool(rs),
        first_prefix_divergence=None if first is None else dict(
            index=first, left=lp[first] if first < len(lp) else None,
            right=rp[first] if first < len(rp) else None),
        alignment=alignment)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('left', type=Path)
    parser.add_argument('right', type=Path, nargs='?')
    parser.add_argument('--tohost-address', type=lambda x: int(x, 0), default=0x801ff000)
    parser.add_argument('--require-tohost', action='store_true')
    args = parser.parse_args()
    try:
        result = compare(args.left, args.right, args.tohost_address, args.require_tohost)
    except (ValueError, KeyError, TypeError) as error:
        print(json.dumps(dict(passed=False, error=str(error)), indent=2))
        raise SystemExit(1)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['passed'] else 1)
