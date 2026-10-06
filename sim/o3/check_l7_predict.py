"""L7a 9.2: trace-derived snapshot deltas and cross-group consistency.

Never uses RTL counter state. Samples come from retired SD data, independently
cross-checked against the preceding retired CSR read's register result.
"""
import argparse
import json
from pathlib import Path

MASK = (1 << 64) - 1
SAMPLES = 0x80100000
EVENTS = {
    'A': ['UBTB_HIT','SLOW_OVERRIDE','PREDECODE_REDIRECT','REDIRECT_EXEC',
          'CMT_REGION','CMT_MISPRED_REGION','UNUSED6','UNUSED7'],
    'B': ['CMT_REGION','FAST_OK_SLOW_OK','FAST_OK_SLOW_BAD','FAST_BAD_SLOW_OK',
          'FAST_BAD_SLOW_BAD','REDIRECT_EXEC','UNUSED6','UNUSED7'],
}


def number(value):
    return int(value, 0) if isinstance(value, str) else int(value)


def extract(path, group, layout):
    snapshots = [[None] * 8 for _ in range(6)]
    markers = {}
    preceding_read = None
    frozen = False
    trace = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    if trace and trace[0]['type'] == 'header':
        header = trace.pop(0)
        assert header['format'] == 'cislc-o3-tandem' and header['version'] == 2
    dynamic_cfi = [0, 0, 0]
    for record in trace:
        assert record['type'] == 'retire', f'{group}: unexpected trap at {record["pc"]}'
        word = number(record['instruction'])
        pc = number(record['pc'])
        if word & 0x7f in (0x63, 0x6f, 0x67):
            for segment in range(1, 4):
                within = layout[f'segment{segment}_begin'] <= pc < layout[f'segment{segment}_end']
                if segment == 2:
                    within |= layout['level1'] <= pc < layout['final_checks']
                if within:
                    dynamic_cfi[segment-1] += 1
        if word & 0x7f == 0x73:
            addr = word >> 20
            op = (word >> 12) & 7
            if addr == 0x320 and op == 1:
                frozen = number(record['csr_wdata']) & 0x7f8 == 0x7f8
            if 0xb03 <= addr <= 0xb0a and op == 2 and (word >> 15) & 31 == 0:
                assert frozen, f'{group}: HPM read while sampling is not frozen'
                preceding_read = (addr - 0xb03, number(record['rd_wdata']))
        if record['mem_kind'] != 'store':
            continue
        addr, value = number(record['mem_addr']), number(record['mem_data'])
        if SAMPLES <= addr < SAMPLES + 384:
            assert record['mem_size'] == 8 and addr % 8 == 0
            row, col = divmod((addr-SAMPLES)//8, 8)
            assert snapshots[row][col] is None, f'{group}: duplicate snapshot store'
            assert preceding_read == (col, value), f'{group}: CSR read / store mismatch row={row} col={col}'
            snapshots[row][col] = value
            preceding_read = None
        elif SAMPLES + 384 <= addr < SAMPLES + 408:
            markers[(addr-SAMPLES-384)//8] = value
    assert all(v is not None for row in snapshots for v in row), f'{group}: missing snapshots'
    assert dynamic_cfi[:2] == [2001, 2500], f'{group}: dynamic CFI denominators {dynamic_cfi}'
    assert any(r['mem_kind']=='store' and number(r['mem_addr'])==0x801ff000
               and number(r['mem_data'])==1 for r in trace), f'{group}: missing PASS tohost'
    deltas = [dict(zip(EVENTS[group], ((b-a)&MASK for a,b in zip(snapshots[2*s],snapshots[2*s+1]))))
              for s in range(3)]
    for values in deltas:
        assert values['UNUSED6'] == values['UNUSED7'] == 0
    if group == 'B':
        for segment, values in enumerate(deltas, 1):
            total = sum(values[name] for name in EVENTS['B'][1:5])
            assert total == values['CMT_REGION'], f'B segment{segment}: classification sum mismatch'
    else:
        assert set(markers) == {0,1,2}, 'A: missing performance markers'
        wanted = [int(deltas[0]['REDIRECT_EXEC']*4 < 2001),
                  int(deltas[1]['REDIRECT_EXEC']*4 < 2500),
                  int(deltas[2]['SLOW_OVERRIDE'] > 0)]
        assert [markers[n] for n in range(3)] == wanted, 'A: performance marker disagrees with trace'
    return {'deltas': deltas, 'performance_markers': markers, 'retired': len(trace),
            'dynamic_cfi': dynamic_cfi}


def compare_groups(result):
    for segment in range(3):
        for event in ('CMT_REGION','REDIRECT_EXEC'):
            a,b = (result[g]['deltas'][segment][event] for g in ('A','B'))
            assert a == b, f'segment{segment+1}: A/B {event} {a} != {b}'


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--a', required=True)
    p.add_argument('--b', required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--layout', required=True)
    args = p.parse_args()
    layout = json.loads(Path(args.layout).read_text())
    result = {g: extract(path, g, layout) for g,path in [('A',args.a),('B',args.b)]}
    compare_groups(result)
    Path(args.output).write_text(json.dumps(result, indent=2)+'\n')
    for segment in range(3):
        print(f'segment {segment+1}: A={result["A"]["deltas"][segment]} B={result["B"]["deltas"][segment]}')
    for marker, passed in result['A']['performance_markers'].items():
        print(f'PERFORMANCE {marker}: {"PASS" if passed else "KNOWN_ISSUE"}')
    print('L7_PREDICT_CORRECTNESS_PASS groups=A,B segments=3')


if __name__ == '__main__':
    main()
