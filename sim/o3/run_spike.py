#!/usr/bin/env python3
"""Lockstep batch runner: retain every failure and continue all requested seeds."""
import argparse
import json
import os
import re
import subprocess
from pathlib import Path
from gen_random import generate, TOHOST


def seeds(text):
    result = []
    for part in text.split(','):
        if '-' in part:
            lo, hi = map(int, part.split('-'))
            result.extend(range(lo, hi + 1))
        else:
            result.append(int(part))
    return result


def run(command, log, inject=None):
    env = {k: v for k, v in os.environ.items() if k != 'O3_INJECT'}
    if inject:
        env['O3_INJECT'] = inject
    try:
        r = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, env=env, timeout=300)
        code, output = r.returncode, r.stdout
    except subprocess.TimeoutExpired as e:
        code = 3
        output = (e.stdout or b'').decode() if isinstance(e.stdout, bytes) else (e.stdout or '')
        output += '\nHOST_TIMEOUT seconds=300\n'
    log.write_text(output)
    return code, output


def main():
    p = argparse.ArgumentParser()
    p.add_argument('mode', choices=['random', 'selftest'])
    p.add_argument('--sim', required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--seeds', default='1-200')
    p.add_argument('--target', type=int, default=3000)
    a = p.parse_args()
    binary = str(Path(a.sim).resolve())
    out = Path(a.output).resolve()
    out.mkdir(parents=True, exist_ok=True)
    results = []
    if a.mode == 'selftest':
        cases = [('pc', 0, 'pc'), ('reg', 2, 'rd_wdata'), ('load', 4, 'mem_data'),
                 ('store_addr', 3, 'mem_addr'), ('store_data', 3, 'mem_data')]
        for kind, index, field in cases:
            code, log = run([binary, '--spike', '--image', 'tests/dcache_data.hex',
                             '--trace', str(out / f'{kind}.jsonl'), '--max-retires', '7'],
                            out / f'{kind}.log', f'{kind}:{index}')
            mismatch = re.search(r'MISMATCH field=(\w+).*retire_idx=(\d+)', log)
            ok = code == 2 and mismatch and mismatch.groups() == (field, str(index))
            result = {'kind': kind, 'retire_idx': index, 'expected_field': field,
                      'returncode': code, 'status': 'PASS' if ok else 'FAIL'}
            results.append(result)
            print(json.dumps(result), flush=True)
    else:
        for seed in seeds(a.seeds):
            words, meta = generate(seed, a.target)
            image = out / f'seed-{seed}.hex'
            image.write_text('@0x80000000\n' + ''.join(f'{w:08x}\n' for w in words)
                             + '@0x80100000\n' + '00000000\n' * (65536 // 4))
            image.with_suffix('.meta.json').write_text(json.dumps(meta, indent=2) + '\n')
            refcode, reflog = run([binary, '--spike-reference-only', '--image', str(image),
                                  '--trace', '/dev/null', '--tohost-address', hex(TOHOST),
                                  '--max-retires', str(a.target * 2)], out / f'seed-{seed}-reference.log')
            reference = re.search(r'\[o3-reference\] PASS events=(\d+) retired=(\d+)', reflog)
            if refcode or not reference or int(reference.group(1)) != meta['dynamic_target']:
                result = {'seed': seed, 'status': 'GENERATOR_ERROR', 'returncode': refcode,
                          'retired': 0, 'reference_retired': int(reference.group(1)) if reference else 0}
                results.append(result)
                print(json.dumps(result), flush=True)
                continue
            code, log = run([binary, '--spike', '--image', str(image),
                             '--trace', str(out / f'seed-{seed}.jsonl'),
                             '--tohost-address', hex(TOHOST), '--retire-target', str(a.target),
                             '--max-retires', str(1 << 60)], out / f'seed-{seed}.log')
            compared = re.search(r'\[o3-spike\] PASS compared=(\d+) retired=(\d+)', log)
            mismatch = re.search(r'MISMATCH field=(\w+).*retire_idx=(\d+)', log)
            retired = int(compared.group(1)) if compared else int(mismatch.group(2)) if mismatch else 0
            result = {'seed': seed, 'returncode': code, 'events': retired, 'retired': int(compared.group(2)) if compared else 0,
                      'matched': bool(compared), 'dynamic_target': meta['dynamic_target'],
                      'status': 'PASS' if code == 0 and compared and int(compared.group(2)) >= 2000 else 'FAIL',
                      'reference_events': int(reference.group(1)), 'reference_retired': int(reference.group(2)),
                      'first_difference': mismatch.groups() if mismatch else None}
            results.append(result)
            print(json.dumps(result), flush=True)
    summary = {'mode': a.mode, 'ran': len(results),
               'passed': sum(r['status'] == 'PASS' for r in results),
               'failed': sum(r['status'] != 'PASS' for r in results),
               'total_matched_retirements': sum(r.get('retired', 0) for r in results),
               'tests': results}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({k: v for k, v in summary.items() if k != 'tests'}), flush=True)
    return int(summary['failed'] != 0)


if __name__ == '__main__':
    raise SystemExit(main())
