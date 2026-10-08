import os
import random

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def synchronous_read_and_independent_write(dut):
    seed = int(os.environ.get("TEST_SEED", "1"))
    rng = random.Random(seed)
    dut.clk_i.value = 0
    dut.read_en_i.value = 0
    dut.read_addr_i.value = 0
    dut.write_en_i.value = 0
    dut.write_addr_i.value = 0
    dut.write_data_i.value = 0

    async def edge():
        dut.clk_i.value = 0
        await Timer(5, unit="ns")
        dut.clk_i.value = 1
        await Timer(5, unit="ns")

    values = {}
    for addr in range(16):
        value = rng.getrandbits(len(dut.write_data_i))
        values[addr] = value
        dut.write_en_i.value = 1
        dut.write_addr_i.value = addr
        dut.write_data_i.value = value
        await edge()
    dut.write_en_i.value = 0

    for read_addr in range(8):
        write_addr = read_addr + 8
        new_value = rng.getrandbits(len(dut.write_data_i))
        dut.read_en_i.value = 1
        dut.read_addr_i.value = read_addr
        dut.write_en_i.value = 1
        dut.write_addr_i.value = write_addr
        dut.write_data_i.value = new_value
        await edge()
        assert int(dut.read_data_o.value) == values[read_addr], (
            f"seed={seed} read={read_addr} write={write_addr}"
        )
        values[write_addr] = new_value

    dut.read_en_i.value = 0
    dut.write_en_i.value = 0
    held = int(dut.read_data_o.value)
    await edge()
    assert int(dut.read_data_o.value) == held
    for addr in range(8, 16):
        dut.read_en_i.value = 1
        dut.read_addr_i.value = addr
        await edge()
        assert int(dut.read_data_o.value) == values[addr], f"seed={seed} addr={addr}"

@cocotb.test()
async def allowed_collision_is_poisoned(dut):
    if os.environ.get('ALLOW_COLLISION','0')!='1': return
    async def edge():
        dut.clk_i.value=0;await Timer(1,unit='ns');dut.clk_i.value=1;await Timer(1,unit='ns')
    dut.read_en_i.value=0;dut.write_en_i.value=1;dut.write_addr_i.value=5;dut.write_data_i.value=0x12345;await edge()
    dut.read_en_i.value=1;dut.read_addr_i.value=5;dut.write_data_i.value=0xabcde;await edge()
    assert int(dut.read_data_o.value)==(((1<<len(dut.read_data_o))-1)^0x12345)
    dut.write_en_i.value=0;await edge();assert int(dut.read_data_o.value)==0xabcde
