import os,random
import cocotb
from cocotb.triggers import Timer
async def edge(d):
 d.clk.value=0;await Timer(1,unit='ns');d.clk.value=1;await Timer(1,unit='ns');d.clk.value=0;await Timer(1,unit='ns')
@cocotb.test()
async def sleep_same_cycle_wake_and_random(d):
 d.clk.value=0;d.retire_i.value=0;d.mip_i.value=0;d.mie_i.value=0
 d.rst.value=1;await edge(d);d.rst.value=0
 assert int(d.sleeping_o.value)==0
 d.retire_i.value=1;await edge(d);d.retire_i.value=0
 assert int(d.sleeping_o.value)==1 and int(d.stall_o.value)==1
 d.mip_i.value=8;await edge(d);assert int(d.sleeping_o.value)==1 # locally disabled pending does not wake
 d.mie_i.value=8;await edge(d);assert int(d.sleeping_o.value)==0
 d.retire_i.value=1;await edge(d);assert int(d.sleeping_o.value)==0 # wake already present on retirement
 rng=random.Random(int(os.getenv('TEST_SEED','1')));sleep=False
 for _ in range(200):
  mip,mie=rng.getrandbits(14),rng.getrandbits(14);retire=rng.choice((False,True))
  d.mip_i.value=mip;d.mie_i.value=mie;d.retire_i.value=retire
  sleep=False if mip&mie else sleep or retire
  await edge(d);assert bool(int(d.sleeping_o.value))==sleep
