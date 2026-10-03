import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def four_integer_uops_through_icache_l2_axi(dut):
    """The whole core must refill both cache levels before retiring code."""
    base = 0x80000000
    instructions = [0x00100093, 0x00200113, 0x00300193, 0x00400213]
    dut.clk_i.value = 0
    dut.rst_i.value = 1
    dut.reset_pc_i.value = base
    dut.dtcm_init_valid_i.value = 0
    dut.dtcm_init_addr_i.value = 0
    dut.dtcm_init_wdata_i.value = 0
    dut.dtcm_init_wmask_i.value = 0
    dut.axi_init_valid_i.value = 1
    dut.axi_init_addr_i.value = base
    dut.axi_init_data_i.value = sum(word << (32*idx) for idx, word in enumerate(instructions))
    dut.axi_init_wmask_i.value = 0xffff

    async def tick():
        dut.clk_i.value = 0
        await Timer(5, unit="ns")
        rows = []
        for lane in range(len(dut.tandem_pc_o)):
            if (int(dut.tandem_valid_o.value) >> lane) & 1:
                rows.append((
                    int(dut.tandem_pc_o[lane].value),
                    int(dut.tandem_instruction_o[lane].value),
                    int(dut.tandem_rd_o[lane].value),
                    int(dut.tandem_rd_wdata_o[lane].value),
                ))
        assert int(dut.fatal_o.value) == 0
        assert int(dut.inclusion_err_o.value) == 0
        dut.clk_i.value = 1
        await Timer(5, unit="ns")
        return rows

    for _ in range(5):
        await tick()
    dut.axi_init_valid_i.value = 0
    dut.rst_i.value = 0
    retired = []
    for cycle in range(160):
        retired.extend(await tick())
        if len(retired) >= 4:
            break
    assert int(dut.icache_refill_count_o.value) >= 1, "ICache refill did not occur"
    assert retired[:4] == [
        (base + 4*idx, instructions[idx], idx+1, idx+1)
        for idx in range(4)
    ], f"cycle={cycle} retired={retired}"
