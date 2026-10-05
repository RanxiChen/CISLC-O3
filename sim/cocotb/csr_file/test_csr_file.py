import os, random
import cocotb
from cocotb.triggers import Timer
async def settle(): await Timer(1,unit="ns")
async def edge(d):
    d.clk.value=0; await settle(); d.clk.value=1; await settle(); d.clk.value=0; await settle()

@cocotb.test()
async def zicsr_warl_traps_counters(d):
    for n in ['clk','req_valid_i','write_i','op_i','addr_i','data_i','retired_i','trap_i','xret_i','cause_i','epc_i','tval_i']:getattr(d,n).value=0
    d.rst.value=1;await edge(d);d.rst.value=0
    state={0x300:0x1800,0x301:0x8000000000001100,0x304:0,0x305:0x200,0x340:0,0x341:0,0x342:0,0x343:0,0x344:0,0xf11:0,0xf12:0,0xf13:0,0xf14:0}
    async def access(addr,op=2,data=0,write=False):
        d.req_valid_i.value=1;d.addr_i.value=addr;d.op_i.value=op;d.data_i.value=data;d.write_i.value=write;await settle()
        old=state.get(addr,0);illegal=addr not in state or (write and addr>>10==3)
        assert int(d.illegal_o.value)==illegal,(hex(addr),op,data)
        if addr in state:assert int(d.read_o.value)==old,(hex(addr),old,int(d.read_o.value))
        if write and not illegal:
            new=data if op==1 else old|data if op==2 else old&~data
            if addr==0x300:new=0x1800|(new&0x88)
            if addr==0x301:new=0x8000000000001100
            if addr==0x304:new&=0x888
            if addr==0x305:new=(new&~3)|(1 if new&3==1 else 0)
            if addr==0x341:new&=~3
            if addr==0x344:new=0
            new&=(1<<64)-1
            assert int(d.write_o.value)==new
            state[addr]=new
        await edge(d);d.req_valid_i.value=0
    for a in state:await access(a)
    await access(0xf14,1,123,True);await access(0x999,1,123,True)
    rng=random.Random(int(os.getenv('TEST_SEED','1')))
    for cycle in range(400):await access(rng.choice(list(state)),rng.randrange(1,4),rng.getrandbits(64),rng.choice([False,True]))
    await access(0x300,1,8,True);await access(0x305,1,0x80001001,True)
    d.trap_i.value=1;d.epc_i.value=0x80000040;d.cause_i.value=11;d.tval_i.value=0;await settle();assert int(d.target_o.value)==0x80001000;await edge(d);d.trap_i.value=0
    state[0x300]=0x1880;state[0x341]=0x80000040;state[0x342]=11;state[0x343]=0
    for a in [0x300,0x341,0x342,0x343]:await access(a)
    d.trap_i.value=1;d.xret_i.value=1;await settle();assert int(d.target_o.value)==0x80000040;await edge(d);d.trap_i.value=0;d.xret_i.value=0;state[0x300]=0x1888;await access(0x300)
    # Counter writes and retirement increments are checked against arithmetic, not RTL state.
    d.addr_i.value=0xb02;d.op_i.value=1;d.data_i.value=50;d.write_i.value=1;d.req_valid_i.value=1;await edge(d)
    d.req_valid_i.value=0;d.retired_i.value=4;await edge(d);d.retired_i.value=0;d.addr_i.value=0xc02;await settle();assert int(d.read_o.value)==54
