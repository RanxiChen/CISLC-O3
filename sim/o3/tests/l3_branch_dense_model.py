"""Fixed RV64I program and architectural oracle; never consumes DUT traces.

40 straight-line groups cross 128 FTQ regions and reuse checkpoints >16 times.
The first miss/unknown store creates replay; each group has correct BNE, taken
BEQ, JAL link, wrong register/store/load, dependent ALU and cached readback.
The interpreter walks architectural PCs and memory; its output is frozen in git.
"""
import json
from pathlib import Path

BASE, DATA, GROUPS = 0x80000000, 0x80010000, 40
MASK = (1 << 64) - 1

def i(op, rd, rs, imm, f=0):
    return (imm & 4095) << 20 | rs << 15 | f << 12 | rd << 7 | op

def sd(rs, off, base=1):
    return (off >> 5) << 25 | rs << 20 | base << 15 | 3 << 12 | (off & 31) << 7 | 0x23

def br(f, off, rs1=0, rs2=0):
    return ((off >> 12)&1)<<31 | ((off >> 5)&63)<<25 | rs2<<20 | rs1<<15 | f<<12 | ((off>>1)&15)<<8 | ((off>>11)&1)<<7 | 0x63

def jal(rd, off):
    return ((off>>20)&1)<<31 | ((off>>1)&1023)<<21 | ((off>>11)&1)<<20 | ((off>>12)&255)<<12 | rd<<7 | 0x6f

def program():
    code = [0x00010097, i(0x03,7,1,0,3), sd(7,8), i(0x03,12,1,8,3), i(0x13,13,12,1)]
    for n in range(GROUPS):
        code += [br(1,8), i(0x13,3,0,n+1), i(0x13,4,3,1), br(0,16),
                 i(0x13,30,0,777), sd(30,16), i(0x03,29,1,64,3),
                 jal(5,8), i(0x13,31,0,888), i(0x13,6,5,1),
                 i(0x03,8,1,16,3), sd(4,24), i(0x03,9,1,24,3)]
    return code

def sext(x, bits):
    return x-(1<<bits) if x & (1<<(bits-1)) else x

def expected():
    code = program(); regs = [0]*32
    mem = {DATA: 0x8877665544332211, DATA+8:0, DATA+16:0x1122334455667788, DATA+24:0, DATA+64:0x99}
    pc=BASE; rows=[]
    while pc < BASE+4*len(code):
        w=code[(pc-BASE)//4]; op=w&127; rd=(w>>7)&31; a=(w>>15)&31; b=(w>>20)&31; f=(w>>12)&7
        value=0; write=False; nxt=pc+4
        if op==0x17:
            value=pc+sext(w&0xfffff000,32);write=True
        elif op==0x13:
            assert f==0
            value=regs[a]+sext(w>>20,12);write=True
        elif op==0x03:
            assert f==3
            value=mem.get((regs[a]+sext(w>>20,12))&MASK,0);write=True
        elif op==0x23:
            off=sext((w>>25)<<5 | (w>>7)&31,12)
            mem[(regs[a]+off)&MASK]=regs[b]
        elif op==0x63:
            off=sext((w>>31)<<12 | ((w>>7)&1)<<11 | ((w>>25)&63)<<5 | ((w>>8)&15)<<1,13)
            take=regs[a]==regs[b] if f==0 else regs[a]!=regs[b]
            if take:nxt=pc+off
        elif op==0x6f:
            off=sext((w>>31)<<20 | ((w>>12)&255)<<12 | ((w>>20)&1)<<11 | ((w>>21)&1023)<<1,21)
            value=pc+4;write=True;nxt=pc+off
        else:raise AssertionError(hex(w))
        value &= MASK
        if write and rd:regs[rd]=value
        rows.append(dict(pc=hex(pc),instruction=f'0x{w:08x}',rd=rd,rd_write=write and rd!=0,rd_wdata=hex(value)))
        regs[0]=0;pc=nxt
    assert regs[30]==regs[31]==0 and mem[DATA+16]==0x1122334455667788
    assert regs[9]==GROUPS+1 and regs[12]==0x8877665544332211
    return rows

if __name__=='__main__':
    root=Path(__file__).parent
    code=program();lines=['# Frozen architectural input: see l3_branch_dense_model.py','@0x80000000']+[f'{w:08x}' for w in code]
    lines+=['@0x80010000','44332211','88776655','00000000','00000000','55667788','11223344','00000000','00000000','@0x80010040','00000099','00000000']
    (root/'l3_branch_dense.hex').write_text('\n'.join(lines)+'\n')
    (root/'l3_branch_dense.expected.json').write_text(json.dumps(expected(),indent=2)+'\n')
    print(f'fixed program words={len(code)} retires={len(expected())} correct={GROUPS} mispredict={2*GROUPS}')
