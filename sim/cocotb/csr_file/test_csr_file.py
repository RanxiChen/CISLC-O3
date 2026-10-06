import os, random
import cocotb
from cocotb.triggers import Timer
async def settle(): await Timer(1,unit="ns")
async def edge(d):
    d.clk.value=0; await settle(); d.clk.value=1; await settle(); d.clk.value=0; await settle()

@cocotb.test()
async def zicsr_warl_traps_counters(d):
    for n in ['clk','req_valid_i','write_i','op_i','addr_i','data_i','retired_i','fe_perf_i','be_perf_i','trap_i','xret_i','cause_i','epc_i','tval_i']:getattr(d,n).value=0
    d.rst.value=1;await edge(d);d.rst.value=0
    state={0x300:0x1800,0x301:0x8000000000001104,0x304:0,0x305:0x200,0x340:0,0x341:0,0x342:0,0x343:0,0x344:0,0xf11:0,0xf12:0,0xf13:0,0xf14:0}
    async def access(addr,op=2,data=0,write=False):
        d.req_valid_i.value=1;d.addr_i.value=addr;d.op_i.value=op;d.data_i.value=data;d.write_i.value=write;await settle()
        old=state.get(addr,0);illegal=addr not in state or (write and addr>>10==3)
        assert int(d.illegal_o.value)==illegal,(hex(addr),op,data)
        if addr in state:assert int(d.read_o.value)==old,(hex(addr),old,int(d.read_o.value))
        if write and not illegal:
            new=data if op==1 else old|data if op==2 else old&~data
            if addr==0x300:new=0x1800|(new&0x88)
            if addr==0x301:new=0x8000000000001104
            if addr==0x304:new&=0x888
            if addr==0x305:new=(new&~3)|(1 if new&3==1 else 0)
            if addr==0x341:new&=~1
            if addr==0x344:new=0
            new&=(1<<64)-1
            assert int(d.write_o.value)==new
            state[addr]=new
        await edge(d);d.req_valid_i.value=0
    for a in state:await access(a)
    await access(0x341,1,0x80000002,True);await access(0x341)
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

@cocotb.test()
async def hpm_routed_through_csr_file(d):
    """L7a 6.3: HPM addresses are served by hpm_counters via csr_file; events reach the counters."""
    for n in ['clk','req_valid_i','write_i','op_i','addr_i','data_i','retired_i','fe_perf_i','be_perf_i','trap_i','xret_i','cause_i','epc_i','tval_i']:getattr(d,n).value=0
    d.rst.value=1;await edge(d);d.rst.value=0
    async def access(addr,data=0,write=False,op=1):
        d.req_valid_i.value=1;d.addr_i.value=addr;d.op_i.value=op;d.data_i.value=data;d.write_i.value=write;await settle()
        r=int(d.read_o.value),int(d.illegal_o.value),int(d.write_o.value);await edge(d);d.req_valid_i.value=0;d.write_i.value=0;await settle();return r
    fw=int(d.fe_w_o.value);bw=int(d.be_w_o.value)
    assert (await access(0x323,0x0102,True))[1]==0   # mhpmevent3 = FE UBTB_HIT
    assert (await access(0x324,0x0201,True))[1]==0   # mhpmevent4 = BE event 1
    _,ill,wo=await access(0x325,(1<<64)-1,True);assert ill==0 and wo==0xffff
    assert (await access(0x32b,5,True))[1]==0        # mhpmevent11: legal, ignored
    assert (await access(0xc03,1,True))[1]==1        # read-only alias write illegal
    d.fe_perf_i.value=3<<(2*fw);d.be_perf_i.value=2<<(1*bw)
    for _ in range(5):await edge(d)
    d.fe_perf_i.value=0;d.be_perf_i.value=0
    r3,i3,_=await access(0xb03);r4,_,_=await access(0xb04);a3,ai,_=await access(0xc03);e11,_,_=await access(0x32b)
    assert (r3,i3,r4,a3,ai,e11)==(15,0,10,15,0,0),(r3,i3,r4,a3,ai,e11)
    # A legal trap cycle has no active CSR request; counters remain intact.
    d.trap_i.value=1;d.req_valid_i.value=0;await edge(d);d.trap_i.value=0
    assert (await access(0xb03,7,True))[0]==15
    assert (await access(0xb03))[0]==7


@cocotb.test()
async def trap_xret_stale_payload_and_live_hpm(d):
    for n in ['clk','req_valid_i','write_i','op_i','addr_i','data_i','retired_i','fe_perf_i','be_perf_i','trap_i','xret_i','cause_i','epc_i','tval_i']:
        getattr(d,n).value=0
    d.rst.value=1;await edge(d);d.rst.value=0
    async def access(addr, data=0, write=False, op=1):
        d.req_valid_i.value=1;d.addr_i.value=addr;d.op_i.value=op;d.data_i.value=data;d.write_i.value=write
        await settle()
        result=tuple(int(getattr(d,n).value) for n in ('read_o','illegal_o','write_o'))
        await edge(d);d.req_valid_i.value=0;d.write_i.value=0
        return result
    await access(0x323,0x0101,True)
    await access(0x320,1,True)  # freeze mcycle to make unintended writes visible
    await access(0xb00,123,True)
    fw=int(d.fe_w_o.value)
    d.fe_perf_i.value=2<<fw
    # trap and xRET exclude active CSR requests; stale write payload is legal.
    for xret in (0,1):
        d.trap_i.value=1;d.xret_i.value=xret;d.req_valid_i.value=0
        d.addr_i.value=0xb00;d.op_i.value=1;d.write_i.value=1;d.data_i.value=999
        d.epc_i.value=0x80000040;d.retired_i.value=xret
        await edge(d)
    d.trap_i.value=0;d.xret_i.value=0;d.write_i.value=0;d.retired_i.value=0;d.fe_perf_i.value=0
    assert (await access(0xb00))[0]==123
    assert (await access(0xb03))[0]==4
    assert (await access(0xb02))[0]==1
    # RMW and U21 normalized write observations also survive csr_file routing.
    assert await access(0xb03,0x10,True,2)==(4,0,20)
    assert await access(0xb03,4,True,3)==(20,0,16)
    for addr in (0xb0b,0xb1f,0x32b,0x33f):
        for op in (1,2,3):
            assert await access(addr,(1<<64)-1,True,op)==(0,0,0)
