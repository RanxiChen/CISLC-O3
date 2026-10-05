import cocotb
from cocotb.triggers import Timer
async def settle(): await Timer(1,unit="ns")
async def edge(d):
    d.clk.value=0;await settle();d.clk.value=1;await settle();d.clk.value=0;await settle()

def ins(f,rd=3,a=1,b=2,word=False):return (1<<25)|(b<<20)|(a<<15)|(f<<12)|(rd<<7)|(0x3b if word else 0x33)
@cocotb.test()
async def pairs_and_atomic_resources(d):
    d.count_i.value=2;d.no_fuse_i.value=0;d.exc_i.value=0;d.resources_i.value=4
    for i in range(4):d.instr_i[i].value=ins(0,rd=i+3)
    for high in [1,2,3]:
        d.instr_i[0].value=ins(high);d.instr_i[1].value=ins(0,rd=4);await settle()
        assert int(d.pair_o.value)==1 and [int(d.role_o[i].value) for i in range(2)]==[1,2]
        d.resources_i.value=1;await settle();assert int(d.accepted_o.value)==0
        d.resources_i.value=2;await settle();assert int(d.accepted_o.value)==2
        d.no_fuse_i.value=1;await settle();assert int(d.pair_o.value)==0;d.no_fuse_i.value=0
        d.exc_i.value=1;await settle();assert int(d.pair_o.value)==0;d.exc_i.value=0
    for instr in [ins(1,rd=1),ins(1,rd=2)]:
        d.instr_i[0].value=instr;await settle();assert int(d.pair_o.value)==0
    d.instr_i[0].value=ins(1);d.instr_i[1].value=ins(0,a=2,b=1);await settle();assert int(d.pair_o.value)==0
    d.instr_i[1].value=ins(0,rd=4);d.count_i.value=1;await settle();assert int(d.pair_o.value)==0
    # Adjacent matching only; a later MUL cannot be searched across a gap.
    d.count_i.value=3;d.instr_i[1].value=ins(5);d.instr_i[2].value=ins(0);await settle();assert int(d.pair_o.value)==0
    for f in [1,2,3]:
        d.instr_i[0].value=ins(f,word=True);await settle();assert int(d.illegal_o.value)&1
