"""Prove A/B PC layout equality before group-specific final checks."""
import argparse
import json
import re
import subprocess
from pathlib import Path


def image(path, prefix):
    listing = subprocess.check_output([prefix+'objdump','-d',path], text=True)
    instructions = {int(pc,16):int(word,16) for pc,word in
                    re.findall(r'^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s', listing, re.M)}
    symbols = {}
    for line in subprocess.check_output([prefix+'nm','-n',path], text=True).splitlines():
        fields = line.split()
        if len(fields)==3:
            symbols[fields[2]]=int(fields[0],16)
    return instructions, symbols


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--a',required=True)
    p.add_argument('--b',required=True)
    p.add_argument('--output',required=True)
    p.add_argument('--prefix',default='riscv64-unknown-elf-')
    args=p.parse_args()
    ia,sa=image(args.a,args.prefix)
    ib,sb=image(args.b,args.prefix)
    names=['_start','final_checks','samples','performance_markers','level1']
    names += [f'segment{s}_{edge}' for s in range(1,4) for edge in ('begin','end')]
    for name in names:
        assert sa[name]==sb[name], f'layout differs at {name}'
    pa={pc:word for pc,word in ia.items() if pc<sa['final_checks']}
    pb={pc:word for pc,word in ib.items() if pc<sb['final_checks']}
    assert pa.keys()==pb.keys(), 'measured instruction addresses differ'
    changes=[]
    events=[(0x0102,0x010f),(0x0105,0x0110),(0x0107,0x0111),
            (0x0108,0x0112),(0x010f,0x0113),(0x0114,0x0108)]
    for pc in sorted(pa):
        if pa[pc]!=pb[pc]:
            n=len(changes)
            assert n<6
            a,b=events[n]
            assert pa[pc]==(a<<20)|(5<<7)|0x13 and pb[pc]==(b<<20)|(5<<7)|0x13
            assert pa[pc+4]==pb[pc+4]==((0x323+n)<<20)|(5<<15)|(1<<12)|0x73
            changes.append(pc)
    assert len(changes)==6, f'expected six event initializers, got {changes}'
    Path(args.output).write_text(json.dumps({name:sa[name] for name in names},indent=2)+'\n')
    print(f'L7_LAYOUT_PASS identical_prefix_instructions={len(pa)} event_immediate_differences=6 fixed_data=0x{sa["samples"]:x}')


if __name__=='__main__':
    main()
