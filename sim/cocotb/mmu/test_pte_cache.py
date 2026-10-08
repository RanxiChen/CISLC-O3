import random,os
import cocotb
from cocotb.triggers import Timer
from l8a_agents import CacheBench, Cpu, OK
async def settle(): await Timer(1,unit='ns')

class Cache:
    """Original PTE test API over the L8a physical request/protocol ports."""
    def __init__(self,d):
        self.d=d;self.e=CacheBench(d);self.mem={};self.fault=set()
        self.rng=random.Random(int(os.getenv('TEST_SEED','1')));self.cy=0
        self.s={};self.seeded=set()
    def sync(self):
        for addr,data in self.mem.items():
            if addr in self.seeded:continue
            line=addr>>6;shift=(addr&63)*8;mask=((1<<64)-1)<<shift
            old=self.e.mem.get(line,0)
            self.e.mem[line]=(old&~mask)|(data<<shift)
            self.e.gold[line]=self.e.mem[line];self.seeded.add(addr)
        self.e.errors={addr>>6 for addr in self.fault}
    def put(self,n,v):
        self.s[n]=v
        if n=='epoch_i':self.d.cur_epoch_i.value=v
        if n in ('read_i','store_i'):
            q=Cpu(self.s['addr_i'],src=3 if n=='read_i' else 1,
                  write=n=='store_i',data=self.s.get('data_i',0))
            if n=='read_i':
                self.e.ptw=q if v else None
                self.d.ptw_req_valid_i.value=v;self.d.ptw_req_i.value=self.e.req_bits(q)
            else:
                self.e.st=q if v else None
                self.d.st_req_valid_i.value=v;self.d.st_req_i.value=self.e.req_bits(q)
    def get(self,n):
        return int(getattr(self.d,{'read_ready_o':'ptw_req_ready_o',
                                 'store_ready_o':'st_req_ready_o'}[n]).value)
    async def tick(self):
        self.sync();self.e.request_ready=self.rng.randrange(4)!=0
        await self.e.tick();self.cy+=1
    async def reset(self):
        self.s=dict(addr_i=0,data_i=0,expected_i=0,set_a_i=0,set_d_i=0,req_epoch_i=0,epoch_i=0)
        await self.e.reset()
    async def request(self,kind,addr,data=0,expected=0,a=0,d=0):
        self.sync()
        self.s.update(addr_i=addr,data_i=data,expected_i=expected,set_a_i=a,set_d_i=d)
        if kind=='read':
            out=self.e.ptw_responses;start=len(out);self.put('read_i',1)
        elif kind=='store':
            out=self.e.st_responses;start=len(out);self.put('store_i',1)
        else:
            out=self.e.ad_responses;start=len(out)
            self.e.ad=(addr,expected,a,d,self.s['req_epoch_i'])
        # Original handshake and response watchdog bounds remain 100 each.
        for _ in range(100):
            await self.tick()
            if (kind=='read' and self.e.ptw is None) or (kind=='store' and self.e.st is None) or (kind=='ad' and self.e.ad is None):break
        else:assert False,('request timeout',kind,addr)
        for _ in range(100):
            if len(out)>start:
                result=out[-1][1]
                if kind=='read':
                    assert result['status']==OK
                    value=result['data'];flags=(0,0,0)
                elif kind=='store':
                    assert result['status']==OK
                    value=0;flags=(0,0,0)
                    line=addr>>6;shift=(addr&63)*8;mask=((1<<64)-1)<<shift
                    self.e.gold[line]=(self.e.gold.get(line,0)&~mask)|(data<<shift)
                else:
                    value=0;flags=(int(bool(result&4)),int(bool(result&2)),int(bool(result&1)))
                    if flags[0]:
                        line=addr>>6;shift=(addr&63)*8
                        self.e.gold[line]=self.e.gold.get(line,0)|(((64 if a else 0)|(128 if d else 0))<<shift)
                await self.tick();return (value,*flags)
            await self.tick()
        assert False,('response timeout',kind,addr)

@cocotb.test()
async def full_pte_compare_hit_miss_cpu_visibility_and_epoch(d):
    t=Cache(d);await t.reset();addr=0x80004008;pte=(0x80010<<10)|7;t.mem[addr]=pte
    assert (await t.request('read',addr))[0]==pte
    r=await t.request('ad',addr,expected=pte^0x400,a=1);assert r[1:]==(0,1,0)
    assert (await t.request('read',addr))[0]==pte
    r=await t.request('ad',addr,expected=pte,a=1);assert r[1:]==(1,0,0)
    assert (await t.request('read',addr))[0]==pte|64
    await t.request('store',addr,data=pte|0x300)
    r=await t.request('ad',addr,expected=pte|64,a=1,d=1);assert r[1:]==(0,1,0)
    assert (await t.request('read',addr))[0]==pte|0x300
    r=await t.request('ad',addr,expected=pte|0x300,a=1,d=1);assert r[1:]==(1,0,0)
    assert (await t.request('read',addr))[0]==pte|0x3c0
    t.put('epoch_i',1);r=await t.request('ad',addr,expected=pte|0x3c0,a=1,d=1);assert r[1:]==(0,1,0)
    # Miss CAS installs the conditional write into the shared physical cache.
    new=0x80008100;t.mem[new]=pte;t.put('req_epoch_i',1)
    r=await t.request('ad',new,expected=pte,a=1);assert r[1:]==(1,0,0)
    assert (await t.request('read',new))[0]==pte|64
    t.fault.add(0x8000c000);r=await t.request('ad',0x8000c000,expected=0,a=1);assert r[1:]==(0,0,1)

@cocotb.test()
async def pte_read_priority_and_random_atomic_operations(d):
    t=Cache(d);await t.reset();addr=0x80004000;t.mem[addr]=7
    t.put('addr_i',addr);t.put('read_i',1);t.put('store_i',1);await settle()
    assert t.get('read_ready_o') and not t.get('store_ready_o')
    await t.tick();t.put('read_i',0);t.put('store_i',0)
    for _ in range(30):await t.tick()
    expected=7
    for cycle in range(80):
        if t.rng.randrange(3)==0:
            expected=t.rng.getrandbits(54)|7;await t.request('store',addr,data=expected)
        else:
            compare=expected if t.rng.randrange(2) else expected^(1<<t.rng.randrange(10,64))
            sa=t.rng.randrange(2);sd=t.rng.randrange(2);r=await t.request('ad',addr,expected=compare,a=sa,d=sd)
            assert r[1:]==((1,0,0) if compare==expected else (0,1,0)),(cycle,r,hex(expected),hex(compare))
            if compare==expected:expected|=(64 if sa else 0)|(128 if sd else 0)
        assert (await t.request('read',addr))[0]==expected,(cycle,hex(expected))
