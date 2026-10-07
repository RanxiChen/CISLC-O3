import random,os
import cocotb
from cocotb.triggers import Timer
async def settle(): await Timer(1,unit='ns')
class Cache:
    def __init__(self,d):self.d=d;self.mem={};self.q=[];self.fault=set();self.rng=random.Random(int(os.getenv('TEST_SEED','1')));self.cy=0
    def put(self,n,v):getattr(self.d,n).value=v
    def get(self,n):return int(getattr(self.d,n).value)
    async def tick(self):
        self.put('clk',0);self.put('l2_valid_i',0);self.put('l2_ready_i',int(self.rng.randrange(4)!=0));self.put('wb_ready_i',1)
        if self.q and self.q[0][0]<=self.cy:
            _,line,beat=self.q[0];self.put('l2_valid_i',1);self.put('l2_last_i',int(beat==3));self.put('l2_fault_i',int(line in self.fault))
            self.put('l2_data_i',self.mem.get(line+beat*16,0)|(self.mem.get(line+beat*16+8,0)<<64))
        await settle()
        if self.get('l2_valid_i') and self.get('l2_resp_ready_o'):self.q.pop(0)
        if self.get('wb_o') and self.get('wb_ready_i'):
            addr=self.get('wb_addr_o');data=self.get('wb_data_o')
            for i in range(8):self.mem[addr+i*8]=(data>>(i*64))&((1<<64)-1)
        if self.get('l2_req_o') and self.get('l2_ready_i'):
            addr=self.get('l2_addr_o')
            self.q.extend((self.cy+2+i,addr,i) for i in range(4))
        self.put('clk',1);await settle();self.put('clk',0);await settle();self.cy+=1
    async def reset(self):
        for n in ('clk','read_i','store_i','ad_i','addr_i','data_i','expected_i','set_a_i','set_d_i','req_epoch_i','epoch_i','l2_valid_i','l2_last_i','l2_fault_i','l2_data_i','l2_ready_i','wb_ready_i'):self.put(n,0)
        self.put('rst',1);await self.tick();self.put('rst',0)
    async def request(self,kind,addr,data=0,expected=0,a=0,d=0):
        self.put('addr_i',addr);self.put('data_i',data);self.put('expected_i',expected);self.put('set_a_i',a);self.put('set_d_i',d)
        self.put(kind+'_i',1)
        for _ in range(100):
            await settle()
            ready=self.get(kind+'_ready_o');await self.tick()
            if ready:break
        else:assert False,('request timeout',kind,addr)
        self.put(kind+'_i',0)
        for _ in range(100):
            if self.get(kind+'_valid_o'):
                result=(self.get('read_data_o'),self.get('updated_o'),self.get('mismatch_o'),self.get('af_o'))
                await self.tick();return result
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
