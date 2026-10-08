import cocotb
from cocotb.triggers import Timer

@cocotb.test()
async def allowed_collision_is_poisoned(dut):
    async def edge():
        dut.clk_i.value=0;await Timer(1,unit='ns');dut.clk_i.value=1;await Timer(1,unit='ns')
    dut.read_en_i.value=0;dut.write_en_i.value=1;dut.write_addr_i.value=5;dut.write_data_i.value=0x12345;await edge()
    dut.read_en_i.value=1;dut.read_addr_i.value=5;dut.write_data_i.value=0xabcde;await edge()
    assert int(dut.read_data_o.value)==(((1<<len(dut.read_data_o))-1)^0x12345)
    dut.write_en_i.value=0;await edge();assert int(dut.read_data_o.value)==0xabcde
