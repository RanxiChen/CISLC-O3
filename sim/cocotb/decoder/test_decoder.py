import os,random
import cocotb
from cocotb.triggers import Timer
@cocotb.test()
async def l10_system_decode(d):
 async def check(insn,op):
  d.instruction_i.value=insn;await Timer(1,unit='ns')
  assert int(d.illegal_o.value)==0,(hex(insn),op)
  assert int(d.sysop_o.value)==op and int(d.serial_o.value)==1 and int(d.block_o.value)==1
 for insn,op in ((0x73,1),(0x100073,2),(0x30200073,3),(0x10200073,4),(0x10500073,5)):
  await check(insn,op)
 rng=random.Random(int(os.getenv('TEST_SEED','1')))
 for rs1,rs2 in [(0,0),(0,31),(31,0),(31,31)]+[(rng.randrange(32),rng.randrange(32)) for _ in range(200)]:
  insn=0x12000073|(rs1<<15)|(rs2<<20)
  await check(insn,8)
  assert int(d.rs1_read_o.value)==1 and int(d.rs2_read_o.value)==1
  assert bool(int(d.x0_1_o.value))==(rs1==0) and bool(int(d.x0_2_o.value))==(rs2==0)
  d.instruction_i.value=insn|0x80;await Timer(1,unit='ns');assert int(d.illegal_o.value)==1
