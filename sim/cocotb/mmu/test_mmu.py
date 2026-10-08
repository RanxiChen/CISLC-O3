import os,random
import cocotb
from cocotb.triggers import Timer
from mmu_model import translate,Fault,A,D
async def settle(): await Timer(1,unit='ns')
class Tb:
    def __init__(self,d):
        self.d=d;self.mem={};self.fault=set();self.queue=[];self.reads=[];self.cycle=0;self.ad_queue=[];self.ad_ops=[];self.race=None;self.ad_latency=2
        self.rng=random.Random(int(os.getenv('TEST_SEED','1')));self.next_table=0x80002000
    def put(self,n,v): getattr(self.d,n).value=v
    def get(self,n): return int(getattr(self.d,n).value)
    async def tick(self):
        d=self.d;self.put('clk',0);self.put('mem_ready_i',int(self.rng.randrange(4)!=0));self.put('mem_valid_i',0);self.put('ad_valid_i',0);self.put('ad_ready_i',1)
        if self.queue and self.queue[0][0]<=self.cycle:
            _,addr=self.queue.pop(0);self.put('mem_valid_i',1);self.put('mem_data_i',self.mem.get(addr,0));self.put('mem_fault_i',int(addr in self.fault))
        if self.ad_queue and self.ad_queue[0][0]<=self.cycle:
            _,addr,expected,set_a,set_d=self.ad_queue.pop(0)
            if self.race: self.race(addr);self.race=None
            match=self.mem.get(addr,0)==expected
            if match: self.mem[addr]=expected|(64 if set_a else 0)|(128 if set_d else 0)
            self.put('ad_valid_i',1);self.put('ad_updated_i',int(match));self.put('ad_mismatch_i',int(not match))
        await settle()
        if self.get('ad_req_o') and self.get('ad_ready_i'):
            addr=self.get('ad_addr_o');expected=self.get('ad_expected_o');sa=self.get('ad_set_a_o');sd=self.get('ad_set_d_o')
            self.ad_ops.append((addr,expected,sa,sd));self.ad_queue.append((self.cycle+self.ad_latency,addr,expected,sa,sd))
        if self.get('mem_req_o') and self.get('mem_ready_i'):
            addr=self.get('mem_addr_o');self.reads.append(addr);self.queue.append((self.cycle+self.rng.randrange(1,6),addr))
        self.put('clk',1);await settle();self.put('clk',0);await settle();self.cycle+=1
    async def reset(self):
        for n in ('i_probe_i','d1_valid_i','d1_store_i','d1_va_i','d_commit_i','clk','kill_i','i_valid_i','d_valid_i','d_store_i','i_va_i','d_va_i','sum_i','mxr_i','epoch_i','asid_i','sf_valid_i','sf_rs1_x0_i','sf_rs2_x0_i','sf_va_i','sf_asid_i','mem_valid_i','mem_ready_i','mem_fault_i','mem_data_i','deny_read_i','deny_write_i','ad_ready_i','ad_valid_i','ad_updated_i','ad_mismatch_i','ad_fault_i'):
            self.put(n,0)
        self.put('priv_i',1);self.put('mode_i',8);self.put('adue_i',0);self.put('root_i',0x80000);self.put('rst',1)
        await self.tick();await self.tick();self.put('rst',0)
    def map(self,va,pa,flags=0xcf,level=0,global_path=False,root=0x80000000):
        base=root
        for l in range(2,level,-1):
            addr=base+((va>>(12+l*9))&511)*8
            if addr not in self.mem:
                table=self.next_table;self.next_table+=4096;self.mem[addr]=(table>>12)<<10|1|(32 if global_path else 0)
            base=(self.mem[addr]>>10)<<12
        addr=base+((va>>(12+level*9))&511)*8
        self.mem[addr]=(pa>>12)<<10|flags
        return addr
    async def lookup(self,va,cmd='load'):
        side='i' if cmd=='fetch' else 'd';self.put(side+'_va_i',va);self.put('d_store_i',int(cmd=='store'));self.put(side+'_valid_i',1)
        await self.tick();self.put(side+'_valid_i',0)
        assert self.get(side+'_resp_o'),(cmd,hex(va),self.cycle)
        r={k:self.get(side+'_'+k+'_o') for k in ('hit','miss','pf','af','pa')}
        await self.tick();return r
    async def access(self,va,cmd='load',expected=None):
        for _ in range(200):
            r=await self.lookup(va,cmd)
            if not r['miss']:
                if expected is not None: assert r[expected],(hex(va),cmd,r,self.reads)
                return r
        assert False,('translation timeout',hex(va),cmd,self.reads)
    async def fence(self,va=None,asid=None):
        self.put('sf_rs1_x0_i',int(va is None));self.put('sf_rs2_x0_i',int(asid is None))
        self.put('sf_va_i',va or 0);self.put('sf_asid_i',asid or 0);self.put('sf_valid_i',1)
        await self.tick();self.put('sf_valid_i',0);await self.tick();assert self.get('sf_done_o');await self.tick()

@cocotb.test()
async def bypass_canonical_three_levels_shortcuts_and_superpages(d):
    t=Tb(d);await t.reset();t.put('mode_i',0)
    for cmd in ('fetch','load','store'):
        r=await t.access(0x11000123,cmd,'hit');assert r['pa']==0x11000123
    t.put('mode_i',8);t.put('priv_i',3);assert (await t.access(0x80000100,'load','hit'))['pa']==0x80000100
    t.put('priv_i',1)
    for va in (1<<39,0xffffff0000000000): await t.access(va,'load','pf')
    assert not t.reads
    for va in (0x4000,0x5000,0x204000): t.map(va,0x80010000+va)
    for va,reads in ((0x4000,3),(0x5000,1),(0x204000,2)):
        before=len(t.reads);assert (await t.access(va,'load','hit'))['pa']==0x80010000+va;assert len(t.reads)-before==reads
    for va,pa,level in ((0x400000,0x80200000,1),(0xffffffffc0000000,0x80000000,2)):
        t.map(va,pa,level=level)
        for off in (0,0x1234,0x1ffff8): assert (await t.access((va+off)&((1<<64)-1),'load','hit'))['pa']==pa+off

@cocotb.test()
async def malformed_pte_read_fault_and_permission_matrix(d):
    t=Tb(d);await t.reset()
    for flags in (0,5,0xcf|(1<<54)):
        t.map(0x4000,0x80010000,flags=flags);await t.fence();await t.access(0x4000,'load','pf')
    t.map(0x400000,0x80001000,level=1);await t.fence();await t.access(0x400000,'load','pf')
    p=t.map(0x4000,0x80010000);t.fault.add(p);await t.fence();await t.access(0x4000,'load','af');t.fault.clear()
    for priv in (0,1):
      for u in (0,16):
       for flags in (0xc3,0xc9,0xc7,0xcf):
        for sum_ in (0,1):
         for mxr in (0,1):
          t.put('priv_i',priv);t.put('sum_i',sum_);t.put('mxr_i',mxr);t.map(0x4000,0x80010000,flags|u);await t.fence()
          for cmd in ('load','store','fetch'):
            try: pa,g=translate(t.mem,0x4000,0x80000,priv,cmd,bool(sum_),bool(mxr));expected='hit'
            except Fault as f: expected=f.kind
            r=await t.access(0x4000,cmd,expected)
            if expected=='hit': assert r['pa']==pa
    t.put('priv_i',1);t.put('sum_i',0);t.put('mxr_i',0)
    for flags,cmd in ((0xf,'load'),(0x4f,'store')):
        t.map(0x4000,0x80010000,flags);await t.fence();await t.access(0x4000,cmd,'pf')

@cocotb.test()
async def asid_global_sfence_nonblocking_epoch_and_kill(d):
    t=Tb(d);await t.reset()
    t.map(0x4000,0x80010000);t.map(0x5000,0x80011000);t.map(0x400000,0x80200000,level=1)
    await t.access(0x4000,'load','hit');await t.access(0x400000,'load','hit')
    # A cold VPN miss does not block a resident VPN on the next cycle.
    assert (await t.lookup(0x5000))['miss'];assert (await t.lookup(0x4000))['hit']
    await t.access(0x5000,'load','hit')
    # rs1!=x0 preserves walk cache, but invalidates matching leaf (including superpage).
    await t.fence(0x4000);before=len(t.reads);await t.access(0x4000,'load','hit');assert len(t.reads)-before==1
    await t.fence(0x401000,0);assert (await t.lookup(0x400000))['miss'];await t.access(0x400000,'load','hit')
    await t.fence(None,1);assert (await t.lookup(0x4000))['hit']
    await t.fence(None,0);before=len(t.reads);await t.access(0x4000,'load','hit');assert len(t.reads)-before==3
    # Global inherited from a nonleaf must survive ASID change and ASID fence.
    await t.fence();t.map(0x80000000,0x80010000,global_path=True);await t.access(0x80000000,'load','hit')
    t.put('asid_i',7);assert (await t.lookup(0x80000000))['hit'];await t.fence(None,0);assert (await t.lookup(0x80000000))['hit']
    # Kill suppresses pending faults; epoch does not install old returns.
    await t.fence();t.map(0x9000,0x80010000,flags=0);assert (await t.lookup(0x9000))['miss']
    t.put('kill_i',1);await t.tick();t.put('kill_i',0)
    for _ in range(40): await t.tick()
    t.map(0x9000,0x80010000);await t.access(0x9000,'load','hit')
    await t.fence();assert (await t.lookup(0xa000))['miss'];t.put('epoch_i',1)
    for _ in range(40): await t.tick()
    t.map(0xa000,0x80012000);await t.access(0xa000,'load','hit')

@cocotb.test()
async def round_robin_and_seeded_sparse_walk_reference(d):
    t=Tb(d);await t.reset();t.map(0x4000,0x80010000);t.map(0x8000,0x80018000)
    t.put('i_va_i',0x4000);t.put('d_va_i',0x8000);t.put('i_valid_i',1);t.put('d_valid_i',1)
    await t.tick();t.put('i_valid_i',0);t.put('d_valid_i',0)
    for _ in range(80): await t.tick()
    assert (await t.lookup(0x4000,'fetch'))['hit'];assert (await t.lookup(0x8000))['hit']
    pages=[]
    for _ in range(60):
        va=t.rng.randrange(16,512)*4096;pa=0x80000000+t.rng.randrange(16,400)*4096
        flags=t.rng.choice((0xcf,0xc3,0xc9,0xdf,0x4f,0xf));t.map(va,pa,flags);pages.append(va)
    await t.fence()
    for cycle in range(100):
        va=t.rng.choice(pages)+t.rng.randrange(4096);cmd=t.rng.choice(('load','store','fetch'))
        try: pa,g=translate(t.mem,va,0x80000,cmd=cmd);expected='hit'
        except Fault as f: expected=f.kind
        r=await t.access(va,cmd,expected)
        if expected=='hit': assert r['pa']==pa,(cycle,hex(va),r,hex(pa))


@cocotb.test()
async def hardware_accessed_compare_retry_permissions_and_pmp(d):
    t=Tb(d);await t.reset();t.put('adue_i',1)
    p=t.map(0x4000,0x80010000,flags=0x0f)
    r=await t.access(0x4000,'load','hit');assert r['pa']==0x80010000
    assert t.mem[p]&A and not t.mem[p]&D
    assert len(t.ad_ops)==1 and t.ad_ops[0][2:]==(1,0)
    # Full-width PTE comparison fails after software replaces the PPN; hardware rewalks.
    await t.fence();t.mem[p]=(0x80010<<10)|0x0f
    t.race=lambda addr:t.mem.__setitem__(addr,(0x80020<<10)|0x0f)
    r=await t.access(0x4000,'load','hit');assert r['pa']==0x80020000 and t.mem[p]&A
    assert len(t.ad_ops)==3
    await t.fence();t.mem[p]=(0x80010<<10)|7;t.put('deny_write_i',1)
    await t.access(0x4000,'load','af');assert not t.mem[p]&A
    assert len(t.ad_ops)==3 # no physical CAS for PMP write rejection
    await t.fence();t.mem[p]=(0x80010<<10)|1;t.put('deny_write_i',0)
    await t.access(0x4000,'load','pf');assert len(t.ad_ops)==3 # permission before A/D

@cocotb.test()
async def queue_head_dirty_rewalk_and_epoch_drain(d):
    t=Tb(d);await t.reset();t.put('adue_i',1)
    p=t.map(0x4000,0x80010000,flags=0x47)
    await t.access(0x4000,'store','hit');assert not t.get('d_dirty_o') and not t.mem[p]&D and not t.ad_ops
    t.put('d_va_i',0x4000);t.put('d_commit_i',1)
    await t.tick();t.put('d_commit_i',0)
    for _ in range(150):
        await t.tick()
        if t.get('d_commit_done_o'):break
    else: assert False,'D updater timeout'
    assert not t.get('d_commit_exc_o') and t.mem[p]&(A|D)==A|D
    assert t.ad_ops[-1][2:]==(1,1)
    # Queue-head rewalk sees a concurrent PTE replacement, not the earlier TLB PPN.
    await t.fence();p=t.map(0x4000,0x80010000,flags=0x47)
    await t.access(0x4000,'store','hit');t.race=lambda addr:t.mem.__setitem__(addr,(0x80020<<10)|0x47)
    async def commit_dirty():
        t.put('d_va_i',0x4000);t.put('d_commit_i',1);await t.tick();t.put('d_commit_i',0)
        for _ in range(150):
            await t.tick()
            if t.get('d_commit_done_o'):return t.get('d_commit_exc_o')
        assert False,'D rewalk timeout'
    assert not await commit_dirty()
    assert t.mem[p]>>10==0x80020 and t.mem[p]&(A|D)==A|D
    await t.tick();await t.fence();t.mem[p]=(0x80010<<10)|0x47;t.put('deny_write_i',1)
    n=len(t.ad_ops);assert await commit_dirty();assert len(t.ad_ops)==n and not t.mem[p]&D
    await t.tick();t.put('deny_write_i',0);t.mem[p]=(0x80010<<10)|0x43
    assert await commit_dirty();assert len(t.ad_ops)==n and not t.mem[p]&D
    await t.tick()
    # Old epoch read response cannot cause a new physical update.
    await t.fence();p=t.map(0x5000,0x80020000,flags=7);assert (await t.lookup(0x5000))['miss']
    t.put('epoch_i',1)
    for _ in range(60): await t.tick()
    assert not t.mem[p]&A
    # Accepted CAS may finish after epoch changes, but must not install the old translation.
    await t.fence();p=t.map(0x6000,0x80030000,flags=7);t.ad_latency=20
    assert (await t.lookup(0x6000))['miss'];count=len(t.ad_ops)
    for _ in range(100):
        await t.tick()
        if len(t.ad_ops)>count:break
    else: assert False,'A update never accepted'
    t.put('epoch_i',2)
    for _ in range(50): await t.tick()
    assert t.mem[p]&A
    assert (await t.lookup(0x6000))['miss']


@cocotb.test()
async def dual_dtlb_bare_hits_and_shared_miss_progress(d):
    t=Tb(d);await t.reset();t.put('mode_i',0)
    for cycle in range(40):
        a=0x80000000+8*cycle;b=0x80010000+8*cycle
        t.put('d_va_i',a);t.put('d1_va_i',b);t.put('d_valid_i',1);t.put('d1_valid_i',1)
        await t.tick()
        assert t.get('d_resp_o') and t.get('d1_resp_o')
        assert t.get('d_hit_o') and t.get('d1_hit_o')
        assert (t.get('d_pa_o'),t.get('d1_pa_o'))==(a,b)
    t.put('d_valid_i',0);t.put('d1_valid_i',0);t.put('mode_i',8)
    t.map(0x4000,0x80010000);t.map(0x8000,0x80020000)
    await t.access(0x4000,'load','hit')
    # Resident port0 progresses while port1 owns the sole miss.
    t.put('d_va_i',0x4008);t.put('d1_va_i',0x8010);t.put('d_valid_i',1);t.put('d1_valid_i',1)
    await t.tick()
    assert t.get('d_hit_o') and t.get('d1_miss_o')
    assert t.get('d_pa_o')==0x80010008
    t.put('d_valid_i',0);t.put('d1_valid_i',0)
    for _ in range(80):await t.tick()
    for cycle in range(40):
        t.put('d_va_i',0x4000+cycle);t.put('d1_va_i',0x8000+cycle)
        t.put('d_valid_i',1);t.put('d1_valid_i',1);await t.tick()
        assert t.get('d_hit_o') and t.get('d1_hit_o')
        assert (t.get('d_pa_o'),t.get('d1_pa_o'))==(0x80010000+cycle,0x80020000+cycle)
    t.put('d_valid_i',0);t.put('d1_valid_i',0)

@cocotb.test()
async def instruction_probe_never_walks_or_counts(d):
 t=Tb(d);await t.reset();t.put('i_probe_i',1)
 for n in range(32):
  r=await t.lookup(0x100000+4096*n,'fetch');assert r['miss']
  assert not t.get('i_walk_o') and not t.get('i_perf_o')
 assert not t.reads and t.get('idle_o')
 t.put('i_probe_i',0);t.map(0x4000,0x80010000)
 assert (await t.access(0x4000,'fetch','hit'))['pa']==0x80010000
 t.map(0xc000,0x80020000)
 assert (await t.access(0xc000,'fetch','hit'))['pa']==0x80020000
 before=len(t.reads);plru=t.get('mon_i_plru_o');t.put('i_probe_i',1)
 for _ in range(8):
  assert (await t.lookup(0x4000,'fetch'))['hit']
  assert not t.get('i_walk_o') and not t.get('i_perf_o') and t.get('mon_i_plru_o')==plru
 t.put('priv_i',0)
 assert (await t.lookup(0x4000,'fetch'))['pf']
 assert not t.get('mon_i_fault_o') and not t.get('i_walk_o') and t.get('mon_i_plru_o')==plru
 assert len(t.reads)==before
