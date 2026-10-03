import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def four_integer_uops_reach_rob_in_order(dut):
    """Exercise the live INT IQ connection through the whole-core L1 path."""
    dut.clk_i.value = 0
    dut.rst_i.value = 1
    dut.reset_pc_i.value = 0x10000000
    dut.itcm_init_valid_i.value = 0
    dut.itcm_init_addr_i.value = 0
    dut.itcm_init_data_i.value = 0
    dut.itcm_init_wmask_i.value = 0
    dut.dtcm_init_valid_i.value = 0
    dut.dtcm_init_addr_i.value = 0
    dut.dtcm_init_wdata_i.value = 0
    dut.dtcm_init_wmask_i.value = 0
    dut.axi_init_valid_i.value = 0
    dut.axi_init_addr_i.value = 0
    dut.axi_init_data_i.value = 0
    dut.axi_init_wmask_i.value = 0

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
        dut.clk_i.value = 1
        await Timer(5, unit="ns")
        return rows

    instructions = [0x00100093, 0x00200113, 0x00300193, 0x00400213]
    for half in range(2):
        dut.itcm_init_valid_i.value = 1
        dut.itcm_init_addr_i.value = 0x10000000 + half*8
        dut.itcm_init_data_i.value = instructions[half*2] | (instructions[half*2+1] << 32)
        dut.itcm_init_wmask_i.value = 0xff
        await tick()
    dut.itcm_init_valid_i.value = 0
    await tick()
    dut.rst_i.value = 0

    retired = []
    for cycle in range(80):
        retired.extend(await tick())
        if len(retired) >= 4:
            break
    assert retired[:4] == [
        (0x10000000 + 4*idx, instructions[idx], idx+1, idx+1)
        for idx in range(4)
    ], f"cycle={cycle} retired={retired}"
