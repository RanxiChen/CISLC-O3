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


@cocotb.test()
async def long_branch_program_ftq_recycles_and_wrong_path_readback(dut):
    import json
    from pathlib import Path
    root=Path(__file__).resolve().parents[2]/'o3'/'tests'
    expected=json.loads((root/'l3_branch_dense.expected.json').read_text())
    image={};addr=0
    for line in (root/'l3_branch_dense.hex').read_text().splitlines():
        line=line.split('#')[0].strip()
        if not line:continue
        if line.startswith('@'):addr=int(line[1:],0)
        else:image[addr]=int(line,16);addr+=4
    dut.clk_i.value=0;dut.rst_i.value=1;dut.reset_pc_i.value=0x80000000
    dut.dtcm_init_valid_i.value=0;dut.dtcm_init_addr_i.value=0
    dut.dtcm_init_wdata_i.value=0;dut.dtcm_init_wmask_i.value=0
    for beat in sorted({a&~15 for a in image}):
        dut.axi_init_valid_i.value=1;dut.axi_init_addr_i.value=beat
        dut.axi_init_data_i.value=sum(image.get(beat+4*n,0)<<(32*n) for n in range(4))
        dut.axi_init_wmask_i.value=0xffff
        dut.clk_i.value=0;await Timer(5,unit='ns')
        dut.clk_i.value=1;await Timer(5,unit='ns')
    dut.axi_init_valid_i.value=0;dut.rst_i.value=0
    retired=[]
    for cycle in range(30000):
        dut.clk_i.value=0;await Timer(5,unit='ns')
        for lane in range(len(dut.tandem_pc_o)):
            if int(dut.tandem_valid_o.value)>>lane&1:
                e=expected[len(retired)]
                actual=(int(dut.tandem_pc_o[lane].value),int(dut.tandem_instruction_o[lane].value),int(dut.tandem_rd_o[lane].value),bool(int(dut.tandem_rd_write_o.value)>>lane&1))
                want=(int(e['pc'],0),int(e['instruction'],0),e['rd'],e['rd_write'])
                assert actual==want,(cycle,len(retired),actual,want)
                if e['rd_write']:assert int(dut.tandem_rd_wdata_o[lane].value)==int(e['rd_wdata'],0),(cycle,e)
                retired.append(actual)
        assert not int(dut.fatal_o.value) and not int(dut.inclusion_err_o.value)
        dut.clk_i.value=1;await Timer(5,unit='ns')
        if len(retired)==len(expected):break
    assert len(retired)==len(expected),(cycle,len(retired))
    # L7's live predictor changes the L3 sequential-predictor split. The clean
    # f0f4106 pre-L10 Alan baseline is exactly 80 correct / 40 mispredictions;
    # retain exact counts and every existing PC/instruction/register-data check.
    assert int(dut.correct_resolve_count_o.value)==80
    assert int(dut.mispredict_count_o.value)==40
    assert int(dut.load_replay_count_o.value)>0
