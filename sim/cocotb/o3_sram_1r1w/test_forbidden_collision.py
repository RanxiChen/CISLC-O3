import cocotb
from cocotb.triggers import Timer
@cocotb.test()
async def default_collision_must_abort(d):
 d.clk_i.value=0;d.read_en_i.value=1;d.read_addr_i.value=0
 d.write_en_i.value=1;d.write_addr_i.value=0;d.write_data_i.value=0
 await Timer(1,unit='ns');d.clk_i.value=1;await Timer(1,unit='ns')
 assert False,'SRAM default collision assertion did not execute'
