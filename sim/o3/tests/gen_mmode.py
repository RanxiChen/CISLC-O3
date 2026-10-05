#!/usr/bin/env python3
"""Independent fixed encodings for L5: CSR suppression, WARL, trap/return and access faults."""
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from gen_random import i, store, branch, jal
BASE=0x80000000

def csr(addr,rd,op,rs): return (addr<<20)|(rs<<15)|(op<<12)|(rd<<7)|0x73

def generate():
    w=[0x00100097,0x00110197,i(0x13,3,0,3,-12),0x00004217, i(0x13,4,0,4,-12),csr(0x305,0,1,4)]
    # x4=0x80004000; x1=data; x3=0x8010fff8.
    w += [i(0x13,5,0,0,123),csr(0x340,0,1,5),csr(0x340,6,2,0),
          csr(0x340,7,6,0),csr(0x340,8,5,31),csr(0x340,9,7,3),
          csr(0x340,10,6,16),csr(0x300,11,2,0),csr(0x301,12,2,0),
          csr(0xb00,13,2,0),csr(0xc00,14,2,0),csr(0xc02,15,2,0),
          store(3,1,5,0),0x00000073,0x00100073,0x0000000b,
          csr(0x999,17,1,5),csr(0xf14,18,1,5),0x10500073,0x0ff0000f,0x0000100f]
    # Explicit DCache/L2 read and store-probe error, outside the AXI RAM mapping.
    pc=BASE+len(w)*4
    w += [0x00200d97,i(0x13,27,0,27,BASE-pc),i(3,19,3,27,0),store(3,27,5,0)]
    w += [i(0x13,2,0,0,1),store(3,3,2,0),jal(0,0)]
    handler=[csr(0x342,28,2,0),csr(0x341,29,2,0),csr(0x343,30,2,0),
             store(3,1,28,8),store(3,1,29,16),store(3,1,30,24),
             i(0x13,29,0,29,4),csr(0x341,0,1,29),0x30200073]
    return '@0x80000000\n'+''.join(f'{n:08x}\n' for n in w)+'@0x80004000\n'+''.join(f'{n:08x}\n' for n in handler)+'@0x80100000\n'+'00000000\n'*16
if __name__=='__main__':Path(__file__).with_name('mmode.hex').write_text(generate())
