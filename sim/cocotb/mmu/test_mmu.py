import os,random
import cocotb
from cocotb.triggers import Timer
from mmu_model import translate,Fault,A,D
async def settle(): await Timer(1,unit='ns')
class Tb:
    def __init__(self,d):
        self.d=d;self.mem={};self.fault=set();self.queue=[];self.reads=[];self.cycle=0
        self.rng=random.Random(int(os.getenv('TEST_SEED','1')));self.next_table=0x80002000
    def put(self,n,v): getattr(self.d,n).value=v
    def get(self,n): return int(getattr(self.d,n).value)
    async def tick(self):
        d=self.d;self.put('clk',0);self.put('mem_ready_i',int(self.rng.randrange(4)!=0));self.put('mem_valid_i',0)
        if self.queue and self.queue[0][0]<=self.cycle:
            _,addr=self.queue.pop(0);self.put('mem_valid_i',1);self.put('mem_data_i',self.mem.get(addr,0));self.put('mem_fault_i',int(addr in self.fault))
        await settle()
        if self.get('mem_req_o') and self.get('mem_ready_i'):
            addr=self.get('mem_addr_o');self.reads.append(addr);self.queue.append((self.cycle+self.rng.randrange(1,6),addr))
        self.put('clk',1);await settle();self.put('clk',0);await settle();self.cycle+=1
    async def reset(self):
        for n in ('clk','kill_i','i_valid_i','d_valid_i','d_store_i','i_va_i','d_va_i','sum_i','mxr_i','epoch_i','asid_i','sf_valid_i','sf_rs1_x0_i','sf_rs2_x0_i','sf_va_i','sf_asid_i','mem_valid_i','mem_ready_i','mem_fault_i','mem_data_i','deny_read_i','deny_write_i','ad_ready_i','ad_valid_i','ad_updated_i','ad_mismatch_i','ad_fault_i'):
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
