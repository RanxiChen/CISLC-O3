import os,random
import cocotb
from cocotb.triggers import Timer
async def edge(d):
 d.clk.value=0;await Timer(1,unit='ns');d.clk.value=1;await Timer(1,unit='ns');d.clk.value=0;await Timer(1,unit='ns')
# Independent interval model; test construction supplies bounds directly, not decoded DUT entries.
def allowed(regions,addr,size,priv,access):
 for lo,hi,perms,locked in regions:
  if addr<hi and addr+size>lo:
   return lo<=addr and addr+size<=hi and (priv==3 and not locked or all(p in perms for p in access))
 return priv==3
@cocotb.test()
async def modes_priority_boundaries_lock_and_random(d):
 for n in ('clk','valid_i','stall_i','addr_i','bytes_i','rd_i','wr_i','ex_i','priv_i','pma_addr_i','cfg_i','pmpaddr_i'):getattr(d,n).value=0
 d.rst.value=1;await edge(d);d.rst.value=0
 assert int(d.valid_o.value)==0
 n=int(d.entries_o.value);assert n==16
 rng=random.Random(int(os.getenv('TEST_SEED','1')))
 geometries=[([3,(0x80000400>>2)|3],[0,0x0b],[(0,0x80000400,'rw',False)]),
             ([0x80000400>>2],[0x1d],[(0x80000400,0x80000410,'rx',False)]),
             ([(0x80000400>>2)|15],[0x1b],[(0x80000400,0x80000480,'rw',False)]),
             ([(0x80000400>>2)|15,(0x80000400>>2)|31],[0x98,0x1f],
              [(0x80000400,0x80000480,'',True),(0x80000400,0x80000500,'rwx',False)])]
 for addresses,configs,regions in geometries:
  d.cfg_i.value=sum(v<<(8*i) for i,v in enumerate(configs));d.pmpaddr_i.value=sum(v<<(54*i) for i,v in enumerate(addresses))
  probes=[(0x80000400,4),(0x800003ff,2),(0x80000403,2),(0x8000047f,2),(0x80000500,8)]
  probes += [(0x80000300+rng.randrange(768),1<<rng.randrange(4)) for _ in range(100)]
  for addr,size in probes:
   for priv in (0,1,3):
    for access in ('r','w','x'):
     d.valid_i.value=1;d.addr_i.value=addr;d.bytes_i.value=size;d.priv_i.value=priv
     d.rd_i.value=access=='r';d.wr_i.value=access=='w';d.ex_i.value=access=='x'
     await edge(d);exp=allowed(regions,addr,size,priv,access)
     assert int(d.valid_o.value)==1 and bool(int(d.allow_o.value))==exp,(regions,hex(addr),size,priv,access,exp)
     assert bool(int(d.fault_o.value))==(not exp)
 d.stall_i.value=1;old=int(d.allow_o.value);d.valid_i.value=0;await edge(d)
 assert int(d.valid_o.value)==1 and int(d.allow_o.value)==old
 d.stall_i.value=0;await edge(d);assert int(d.valid_o.value)==0

@cocotb.test()
async def pma_full_range_no_bare_high_bit_alias(d):
 rng=random.Random(int(os.getenv('TEST_SEED','1')))
 # User approved L8b migration: preserve every original probe and RNG draw.
 ranges=[(0x80000000,0x100000000,True),(0x11000000,0x11040000,False)]
 mapped_ranges=[(0x02000000,0x80000000,False,False),(0x80000000,0x100000000,True,True)]
 probes=[(a+s,b) for lo,hi,_ in ranges for a in (lo,hi) for s in (-1,0,1) for b in (1,4,8,16)]
 probes += [(0x180000000,8),(0xfffffffffffffff8,16)]
 probes += [(rng.choice([0x11000000,0x80000000,0x100000000])+rng.randrange(-128,128),1<<rng.randrange(5)) for _ in range(200)]
 # Add checks after original generation to retain the original random sequence.
 probes += [(0x02000000+s,b) for s in (-1,0,1) for b in (1,4,8,16)]
 probes += [(0x7fffffff+s,b) for s in (-7,-3,-1,0,1) for b in (1,2,4,8,16)]
 probes += [(rng.choice([0x02000000,0x7fffffff,0x80000000,0x100000000])+rng.randrange(-128,128),1<<rng.randrange(5)) for _ in range(200)]
 for addr,size in probes:
  d.pma_addr_i.value=addr;d.bytes_i.value=size;await Timer(1,unit='ns')
  permitted=[x for x in mapped_ranges if x[0]<=addr and addr+size<=x[1]]
  exists=bool(permitted);cached=exists and permitted[0][2];executable=exists and permitted[0][3]
  io=exists and not cached
  assert (bool(int(d.pma_exists_o.value)),bool(int(d.pma_cache_o.value)),bool(int(d.pma_exec_o.value)),bool(int(d.pma_read_o.value)),bool(int(d.pma_write_o.value)))==(exists,cached,executable,exists,exists),(hex(addr),size)

  assert (bool(int(d.pma_io_o.value)),bool(int(d.pma_amo_o.value)),bool(int(d.pma_rsrv_o.value)))==(io,cached,cached),(hex(addr),size)
