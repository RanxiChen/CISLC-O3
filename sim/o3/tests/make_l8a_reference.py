"""Independent RV64I architectural reference for the self-checking M6 image."""
import argparse,json,struct
from pathlib import Path
M=(1<<64)-1

def sext(value,bits):
    return (value ^ (1<<(bits-1)))-(1<<(bits-1))

def reference(path,tohost=0x801ff000):
    elf=Path(path).read_bytes()
    assert elf[:6]==b'\x7fELF\x02\x01'
    entry,phoff=struct.unpack_from('<QQ',elf,24)
    entsize,count=struct.unpack_from('<HH',elf,54)
    memory={}
    for n in range(count):
        typ,flags,off,va,pa,filesz,memsz,align=struct.unpack_from('<IIQQQQQQ',elf,phoff+n*entsize)
        if typ==1:
            for i,b in enumerate(elf[off:off+filesz]):memory[va+i]=b
    def read(a,n):return sum(memory.get(a+i,0)<<(8*i) for i in range(n))
    regs=[0]*32;pc=entry;events=[]
    for order in range(200000):
        inst=read(pc,4);op=inst&127;rd=(inst>>7)&31;f3=(inst>>12)&7
        rs1=(inst>>15)&31;rs2=(inst>>20)&31;f7=inst>>25
        a,b=regs[rs1],regs[rs2];imm=sext(inst>>20,12);nxt=pc+4;value=None
        row=dict(type='retire',order=order,pc=hex(pc),instruction=hex(inst),cycle=order,slot=0)
        if op==0x37:value=sext(inst&0xfffff000,32)
        elif op==0x17:value=pc+sext(inst&0xfffff000,32)
        elif op in (0x13,0x1b):
            if f3==0:value=a+imm
            elif f3==4:value=a^(imm&M)
            elif f3==6:value=a|(imm&M)
            elif f3==7:value=a&(imm&M)
            elif f3==1:value=a<<((inst>>20)&(31 if op==0x1b else 63))
            elif f3==5:value=(sext(a,64) if f7&0x20 else a)>>((inst>>20)&63)
            else:raise AssertionError((hex(pc),hex(inst),'immediate'))
            if op==0x1b:value=sext(value&0xffffffff,32)
        elif op==0x33:
            assert f7 in (0,0x20) and (f7==0 or f3==0),(hex(pc),hex(inst),'unsupported register operation')
            if f3==0:value=a-b if f7==0x20 else a+b
            elif f3==6:value=a|b
            elif f3==4:value=a^b
            elif f3==7:value=a&b
            else:raise AssertionError((hex(pc),hex(inst),'register'))
        elif op==0x03:
            size=1<<(f3&3);addr=(a+imm)&M;value=read(addr,size)
            if f3<4:value=sext(value,8*size)
        elif op==0x23:
            size=1<<f3;simm=sext(((inst>>25)<<5)|((inst>>7)&31),12);addr=(a+simm)&M
            for i in range(size):memory[addr+i]=(b>>(8*i))&255
            row.update(mem_kind='store',mem_addr=hex(addr),mem_size=size,mem_data=hex(b&((1<<(8*size))-1)))
        elif op==0x63:
            branchimm=sext(((inst>>31)<<12)|(((inst>>7)&1)<<11)|(((inst>>25)&63)<<5)|(((inst>>8)&15)<<1),13)
            cond={0:a==b,1:a!=b,4:sext(a,64)<sext(b,64),5:sext(a,64)>=sext(b,64),6:a<b,7:a>=b}[f3]
            if cond:nxt=pc+branchimm
        elif op==0x6f:
            jimm=sext(((inst>>31)<<20)|(((inst>>12)&255)<<12)|(((inst>>20)&1)<<11)|(((inst>>21)&1023)<<1),21)
            value=pc+4;nxt=pc+jimm
        elif op==0x67:value=pc+4;nxt=(a+imm)&~1
        elif op==0x0f:pass
        else:raise AssertionError((hex(pc),hex(inst),'unsupported'))
        if value is not None and rd:regs[rd]=value&M
        regs[0]=0;events.append(row)
        if row.get('mem_kind')=='store' and row['mem_addr']==hex(tohost):
            assert row['mem_data']=='0x1',(order,hex(pc),'self-check failed',row)
            return events
        pc=nxt&M
    raise AssertionError('architectural watchdog')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('elf');p.add_argument('output');a=p.parse_args()
    rows=reference(a.elf)
    with open(a.output,'w') as f:
        f.write(json.dumps(dict(type='header',reference='independent RV64I sequential model'))+'\n')
        for row in rows:f.write(json.dumps(row)+'\n')
    print('architectural reference events',len(rows))
