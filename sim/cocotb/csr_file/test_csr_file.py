import os, random
import cocotb
from cocotb.triggers import Timer
async def settle(): await Timer(1,unit="ns")
async def edge(d):
    d.clk.value=0; await settle(); d.clk.value=1; await settle(); d.clk.value=0; await settle()

@cocotb.test()
async def fp_csr_reset_alias_and_retirement(d):
    for n in ['mtime_i','irq_i','sret_i','interrupt_i','fp_valid_i','fp_dirty_i','fp_flags_i','clk','req_valid_i','write_i','op_i','addr_i','data_i','retired_i','fe_perf_i','be_perf_i','trap_i','xret_i','cause_i','epc_i','tval_i']:
        getattr(d,n).value=0
    d.rst.value=1;await edge(d);d.rst.value=0
    assert int(d.fs_o.value)==0 and int(d.frm_o.value)==0
    async def access(addr,data=0,write=False):
        d.req_valid_i.value=1;d.addr_i.value=addr;d.op_i.value=1
        d.data_i.value=data;d.write_i.value=write;await settle()
        result=int(d.read_o.value),int(d.illegal_o.value)
        await edge(d);d.req_valid_i.value=0;d.write_i.value=0
        return result
    for addr in (1,2,3):assert (await access(addr,255,True))[1]==1
    await access(0x300,1<<13,True)
    assert await access(3)==(0,0)  # illegal writes while Off had no effect
    assert int(d.fs_o.value)==1  # reads leave Initial intact
    await access(3,0xa3,True)
    assert await access(1)==(3,0)
    assert await access(2)==(5,0)  # reserved frm is stored, not clamped
    assert int(d.fs_o.value)==3
    assert (await access(0x300))[0]>>63==1
    await access(3,0,True);await access(0x300,2<<13,True)
    d.fp_valid_i.value=1;d.fp_flags_i.value=0x10;d.fp_dirty_i.value=1
    await edge(d);d.fp_flags_i.value=1;await edge(d)
    d.fp_valid_i.value=0;d.fp_dirty_i.value=0;d.fp_flags_i.value=0
    assert await access(1)==(0x11,0)
    assert int(d.fs_o.value)==3
    await access(0x300,0,True)
    assert (await access(3))[1]==1
    await access(0x300,1<<13,True)
    assert await access(3)==(0x11,0)  # FS changes preserve fcsr

@cocotb.test()
async def zicsr_warl_traps_counters(d):
    for n in ['mtime_i','irq_i','sret_i','interrupt_i','fp_valid_i','fp_dirty_i','fp_flags_i','clk','req_valid_i','write_i','op_i','addr_i','data_i','retired_i','fe_perf_i','be_perf_i','trap_i','xret_i','cause_i','epc_i','tval_i']:getattr(d,n).value=0
    d.rst.value=1;await edge(d);d.rst.value=0
    state={0x300:0xa00001800,0x301:0x800000000014112d,0x304:0,0x305:0x200,0x340:0,0x341:0,0x342:0,0x343:0,0x344:0,0xf11:0,0xf12:0,0xf13:0,0xf14:0}
    async def access(addr,op=2,data=0,write=False):
        d.req_valid_i.value=1;d.addr_i.value=addr;d.op_i.value=op;d.data_i.value=data;d.write_i.value=write;await settle()
        old=state.get(addr,0);illegal=addr not in state or (write and addr>>10==3)
        assert int(d.illegal_o.value)==illegal,(hex(addr),op,data)
        if addr in state:assert int(d.read_o.value)==old,(hex(addr),old,int(d.read_o.value))
        if write and not illegal:
            new=data if op==1 else old|data if op==2 else old&~data
            if addr==0x300:
                new=0xa00000000|(new&sum(1<<n for n in (1,3,5,7,8,11,12,13,14,17,18,19,20,21,22)))
                if (new>>11)&3==2:new&=~(3<<11)
                if (new>>13)&3==3:new|=1<<63
            if addr==0x301:new=0x800000000014112d
            if addr==0x304:new&=0x2aaa
            if addr==0x305:new=(new&~3)|(1 if new&3==1 else 0)
            if addr==0x341:new&=~1
            if addr==0x344:new&=0x2222
            if addr==0x342:
                legal=(new&~((1<<63)|63))==0 and (new&63) in ((1,3,5,7,9,11,13) if new>>63 else (0,1,2,3,4,5,6,7,8,9,11,12,13,15))
                if not legal:new=old
            new&=(1<<64)-1
            assert int(d.write_o.value)==new,(hex(addr),op,hex(data),hex(new),hex(int(d.write_o.value)))
            state[addr]=new
        await edge(d);d.req_valid_i.value=0
    for a in state:await access(a)
    await access(0x341,1,0x80000002,True);await access(0x341)
    await access(0xf14,1,123,True);await access(0x999,1,123,True)
    rng=random.Random(int(os.getenv('TEST_SEED','1')))
    for cycle in range(400):await access(rng.choice(list(state)),rng.randrange(1,4),rng.getrandbits(64),rng.choice([False,True]))
    await access(0x300,1,8,True);await access(0x305,1,0x80001001,True)
    d.trap_i.value=1;d.epc_i.value=0x80000040;d.cause_i.value=11;d.tval_i.value=0;await settle();assert int(d.target_o.value)==0x80001000;await edge(d);d.trap_i.value=0
    state[0x300]=0xa00001880;state[0x341]=0x80000040;state[0x342]=11;state[0x343]=0
    for a in [0x300,0x341,0x342,0x343]:await access(a)
    d.trap_i.value=1;d.xret_i.value=1;await settle();assert int(d.target_o.value)==0x80000040;await edge(d);d.trap_i.value=0;d.xret_i.value=0;state[0x300]=0xa00000088;await access(0x300)
    # Counter writes and retirement increments are checked against arithmetic, not RTL state.
    d.addr_i.value=0xb02;d.op_i.value=1;d.data_i.value=50;d.write_i.value=1;d.req_valid_i.value=1;await edge(d)
    d.req_valid_i.value=0;d.retired_i.value=4;await edge(d);d.retired_i.value=0;d.addr_i.value=0xc02;await settle();assert int(d.read_o.value)==54

@cocotb.test()
async def hpm_routed_through_csr_file(d):
    """L7a 6.3: HPM addresses are served by hpm_counters via csr_file; events reach the counters."""
    for n in ['mtime_i','irq_i','sret_i','interrupt_i','fp_valid_i','fp_dirty_i','fp_flags_i','clk','req_valid_i','write_i','op_i','addr_i','data_i','retired_i','fe_perf_i','be_perf_i','trap_i','xret_i','cause_i','epc_i','tval_i']:getattr(d,n).value=0
    d.rst.value=1;await edge(d);d.rst.value=0
    async def access(addr,data=0,write=False,op=1):
        d.req_valid_i.value=1;d.addr_i.value=addr;d.op_i.value=op;d.data_i.value=data;d.write_i.value=write;await settle()
        r=int(d.read_o.value),int(d.illegal_o.value),int(d.write_o.value);await edge(d);d.req_valid_i.value=0;d.write_i.value=0;await settle();return r
    fw=int(d.fe_w_o.value);bw=int(d.be_w_o.value)
    assert (await access(0x323,0x0102,True))[1]==0   # mhpmevent3 = FE UBTB_HIT
    assert (await access(0x324,0x0201,True))[1]==0   # mhpmevent4 = BE event 1
    _,ill,wo=await access(0x325,(1<<64)-1,True);assert ill==0 and wo==0xf00000000000ffff
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
    for n in ['mtime_i','irq_i','sret_i','interrupt_i','fp_valid_i','fp_dirty_i','fp_flags_i','clk','req_valid_i','write_i','op_i','addr_i','data_i','retired_i','fe_perf_i','be_perf_i','trap_i','xret_i','cause_i','epc_i','tval_i']:
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

class PrivTb:
    def __init__(self,d): self.d=d
    async def reset(self):
        for n in ('clk','req_valid_i','write_i','op_i','addr_i','data_i','retired_i','fe_perf_i','be_perf_i','trap_i','xret_i','sret_i','interrupt_i','cause_i','epc_i','tval_i','mtime_i','irq_i','fp_valid_i','fp_dirty_i','fp_flags_i'):
            getattr(self.d,n).value=0
        self.d.rst.value=1;await edge(self.d);self.d.rst.value=0;await settle()
    async def csr(self,a,v=0,write=False,op=1):
        d=self.d;d.addr_i.value=a;d.data_i.value=v;d.op_i.value=op;d.write_i.value=write;d.req_valid_i.value=1
        await settle();r=(int(d.read_o.value),int(d.illegal_o.value),int(d.refetch_o.value))
        await edge(d);d.req_valid_i.value=0;d.write_i.value=0;return r
    async def trap(self,cause=0,epc=0x80000402,tval=0,interrupt=False,xret=False,sret=False):
        d=self.d;d.trap_i.value=1;d.cause_i.value=cause;d.epc_i.value=epc;d.tval_i.value=tval
        d.interrupt_i.value=interrupt;d.xret_i.value=xret;d.sret_i.value=sret
        await settle();pc=int(d.target_o.value);await edge(d)
        d.trap_i.value=0;d.xret_i.value=0;d.sret_i.value=0;d.interrupt_i.value=0;return pc
    async def enter(self,priv,status=0):
        await self.csr(0x300,status|(priv<<11),True)
        await self.trap(xret=True)
        assert int(self.d.priv_o.value)==priv

@cocotb.test()
async def l10_csr_views_wlrl_and_pmp_lock(d):
    t=PrivTb(d);await t.reset()
    assert (await t.csr(0x300))[0]==0xa00001800
    await t.csr(0x302,(1<<64)-1,True);assert (await t.csr(0x302))[0]==0xb1ff
    await t.csr(0x303,(1<<64)-1,True);assert (await t.csr(0x303))[0]==0x2222
    await t.csr(0x304,(1<<64)-1,True);assert (await t.csr(0x104))[0]==0x2222
    await t.csr(0x144,0x2222,True);assert (await t.csr(0x344))[0]==0x2002 # sip cannot write SEIP/STIP
    for a in (0x342,0x142):
        for legal in (0,9,15,(1<<63)|13):
            await t.csr(a,legal,True);assert (await t.csr(a))[0]==legal
            for illegal in (10,14,(1<<63)|8,1<<40,(1<<63)|(1<<8)|13):
                await t.csr(a,illegal,True);assert (await t.csr(a))[0]==legal
    await t.csr(0x180,0x1234500000000042,True)
    assert (await t.csr(0x180))[0]==0 # T08a unsupported MODE ignores whole write
    await t.csr(0x180,0x123,True);assert (await t.csr(0x180))[0]==0x123
    await t.csr(0x3b0,0x123,True);await t.csr(0x3b1,0x400,True)
    await t.csr(0x3a0,0x8b00,True) # locked TOR entry 1 also locks address 0
    assert (await t.csr(0x3b0,0x567,True))[2]==0
    assert (await t.csr(0x3b0))[0]==0x120
    await t.csr(0x3a0,0,True);assert (await t.csr(0x3a0))[0]==0x8b00
    await t.csr(0x3a2,0x7f,True);assert (await t.csr(0x3a2))[0]==0x1f # reserved bits clear
    await t.csr(0x3a2,2,True);assert (await t.csr(0x3a2))[0]==0 # W without R cleared
    await t.enter(1)
    rng=random.Random(int(os.getenv('TEST_SEED','1')))
    for _ in range(80):
        v=rng.getrandbits(64);await t.csr(0x140,v,True);assert (await t.csr(0x140))[0]==v
    assert (await t.csr(0x300))[1]==1
    await t.csr(0x100,(1<<63)|(3<<13)|(1<<18)|0x122,True)
    assert (await t.csr(0x100))[0]==0x8000000200046122
    await t.csr(0x10a,(1<<64)-1,True);assert (await t.csr(0x10a))[:2]==(0,0)

@cocotb.test()
async def l10_delegation_returns_and_counter_access(d):
    t=PrivTb(d);await t.reset()
    await t.csr(0x305,0x80001001,True);await t.csr(0x105,0x80002001,True)
    await t.csr(0x302,1<<8,True);await t.csr(0x303,1<<1,True)
    await t.csr(0x306,2,True);await t.csr(0x106,2,True)
    await t.csr(0x323,(1<<63)|0x0101,True)
    await t.enter(0,1<<17)
    assert not (int(d.status_o.value)&(1<<17)) # MRET to U clears MPRV
    d.mtime_i.value=123
    assert (await t.csr(0xc01))[:2]==(123,0)
    assert (await t.csr(0xc00))[1]==1
    assert (await t.csr(0xda0))[1]==1
    assert await t.trap(8,tval=0x55)==0x80002000
    assert int(d.priv_o.value)==1
    assert (await t.csr(0x142))[0]==8 and (await t.csr(0x143))[0]==0x55
    assert (await t.csr(0xda0))[0]==0 # mcounteren HPM3 is off
    assert await t.trap(xret=True,sret=True)==0x80000402
    assert int(d.priv_o.value)==0
    assert await t.trap(9)==0x80001000 # S ECALL cause is not delegated by the frozen mask
    assert int(d.priv_o.value)==3
    await t.csr(0x306,0,True);await t.enter(0)
    assert (await t.csr(0xc01))[1]==1
    await t.trap(2);await t.csr(0x306,1<<3,True);await t.enter(1,1<<20)
    assert (await t.csr(0x180))[1]==1 # TVM denies S satp
    assert (await t.csr(0xda0))[0]==8

@cocotb.test()
async def l10_interrupt_priority_sstc_and_overflow(d):
    t=PrivTb(d);await t.reset()
    d.irq_i.value=14
    await t.csr(0x304,0x888,True);assert int(d.irq_take_o.value)==0
    await t.csr(0x300,8,True);await settle()
    assert int(d.irq_cause_o.value)==11 and int(d.irq_take_o.value)==1
    d.irq_i.value=6;await settle();assert int(d.irq_cause_o.value)==3
    d.irq_i.value=4;await settle();assert int(d.irq_cause_o.value)==7
    d.irq_i.value=1
    await t.csr(0x344,2,True,2);assert (await t.csr(0x344))[0]&0x200
    d.irq_i.value=0;assert not ((await t.csr(0x344))[0]&0x200) # RMW did not capture the external SEIP
    await t.csr(0x344,0x20,True);assert (await t.csr(0x344))[0]&0x20
    await t.csr(0x30a,(1<<63)|(1<<61),True);await t.csr(0x14d,20,True)
    d.mtime_i.value=19;assert not ((await t.csr(0x344))[0]&0x20)
    d.mtime_i.value=20;assert (await t.csr(0x344))[0]&0x20
    await t.csr(0x344,0,True);assert (await t.csr(0x344))[0]&0x20 # hardware STIP is read-only
    await t.csr(0x303,0x20,True);await t.csr(0x304,0x20,True);await t.enter(1,2)
    assert int(d.irq_take_o.value)==1 and int(d.irq_cause_o.value)==5
    assert (await t.csr(0x14d))[1]==1 # missing TM authorization
    await t.trap(2);await t.csr(0x306,2,True);await t.enter(1)
    assert (await t.csr(0x14d))[:2]==(20,0)
    await t.trap(2);await t.csr(0x323,0x0101,True);await t.csr(0xb03,(1<<64)-1,True)
    d.fe_perf_i.value=1<<int(d.fe_w_o.value);await edge(d);d.fe_perf_i.value=0
    assert (await t.csr(0xda0))[0]==8
    assert (await t.csr(0x344))[0]&(1<<13)


@cocotb.test()
async def l10_pmp_grain_raw_storage_and_adue_sync(d):
    t=PrivTb(d);await t.reset()
    raw=(1<<53)|0x123
    await t.csr(0x3b0,raw,True)
    assert (await t.csr(0x3b0))[0]==raw&~3
    assert int(d.pmpaddr_o.value)&((1<<54)-1)==raw
    # NA4 preserves just A; other configuration fields still accept writes.
    await t.csr(0x3a0,0x15,True)
    assert (await t.csr(0x3a0))[0]==5
    await t.csr(0x3a0,0x1f,True)
    assert (await t.csr(0x3b0))[0]==raw|1
    await t.csr(0x3a0,0x13,True)
    assert (await t.csr(0x3a0))[0]==0x1b
    await t.csr(0x3a0,0x0b,True)
    assert (await t.csr(0x3b0))[0]==raw&~3
    await t.csr(0x3a0,0x1f,True)
    assert (await t.csr(0x3b0))[0]==raw|1
    # Changing STCE alone, or a repeated ADUE write, does not advance epoch.
    epoch=int(d.epoch_o.value)
    for value,change in (((1<<63)|(1<<61),False),(1<<63,True),
                         (1<<63,False),(0,False),(1<<61,True)):
        result=await t.csr(0x30a,value,True)
        assert bool(result[2])==change
        epoch+=int(change)
        assert int(d.epoch_o.value)==epoch
        assert (await t.csr(0x30a))[0]==value

@cocotb.test()
async def l10_overflow_dominates_mip_software_clear(d):
    t=PrivTb(d);await t.reset()
    await t.csr(0x323,0x0101,True)
    await t.csr(0xb03,(1<<64)-1,True)
    d.fe_perf_i.value=1<<int(d.fe_w_o.value)
    await t.csr(0x344,0,True)
    d.fe_perf_i.value=0
    assert (await t.csr(0xda0))[0]==8
    assert (await t.csr(0x344))[0]&(1<<13)
    # Same counter write replaces an otherwise overflowing increment.
    await t.csr(0x323,0x0101,True)
    await t.csr(0x344,0,True)
    await t.csr(0xb03,(1<<64)-1,True)
    d.fe_perf_i.value=1<<int(d.fe_w_o.value)
    await t.csr(0xb03,17,True)
    d.fe_perf_i.value=0
    assert (await t.csr(0xb03))[0]==17
    assert (await t.csr(0xda0))[0]==0
    assert not ((await t.csr(0x344))[0]&(1<<13))

@cocotb.test()
async def sv39_satp_warl_and_refetch(d):
    t=PrivTb(d);await t.reset()
    value=0x8123000000080000
    assert (await t.csr(0x180,value,True))[2]==1
    assert (await t.csr(0x180))[0]==value
    assert (await t.csr(0x180,0x9123000000080001,True))[2]==0
    assert (await t.csr(0x180))[0]==value
    assert (await t.csr(0x180,0,True))[2]==1
    assert (await t.csr(0x180))[0]==0

@cocotb.test()
async def frontend_feature_csr_warl_nonserial_privilege(d):
 for n in ['mtime_i','irq_i','sret_i','interrupt_i','fp_valid_i','fp_dirty_i','fp_flags_i','clk','req_valid_i','write_i','op_i','addr_i','data_i','retired_i','fe_perf_i','be_perf_i','trap_i','xret_i','cause_i','epc_i','tval_i']:getattr(d,n).value=0
 d.rst.value=1;await edge(d);d.rst.value=0
 async def access(addr,data=0,write=False,op=1):
  d.req_valid_i.value=1;d.addr_i.value=addr;d.data_i.value=data;d.write_i.value=write;d.op_i.value=op;await settle()
  out=(int(d.read_o.value),int(d.illegal_o.value),int(d.refetch_o.value));await edge(d);d.req_valid_i.value=0;return out
 assert await access(0x7c0)==(0,0,0)
 assert await access(0x7c0,0xffff,True)==(0,0,0)
 assert await access(0x7c0)==(3,0,0)
 assert int(d.loop_dis_o.value) and int(d.pf_dis_o.value) and not int(d.epoch_o.value)
 assert await access(0x7c0,1,True,3)==(3,0,0)
 assert await access(0x7c0)==(2,0,0)
 await access(0x300,1<<11,True) # MPP=S, then MRET.
 d.trap_i.value=1;d.xret_i.value=1;await edge(d);d.trap_i.value=0;d.xret_i.value=0
 assert int(d.priv_o.value)==1
 assert (await access(0x7c0,0,True))[1]==1
 assert int(d.pf_dis_o.value)==1
