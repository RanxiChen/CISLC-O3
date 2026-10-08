import cocotb
from cocotb.triggers import Timer
async def settle(): await Timer(1,unit="ns")
async def edge(d):
    d.clk.value=0;await settle();d.clk.value=1;await settle();d.clk.value=0;await settle()

@cocotb.test()
async def redirect_link_hold_hints_and_alignment(d):
    for n in ['clk','grant_i','consume_i','src_i','imm_i','rd_i','rs_i','pc_i','pred_i','rob_i','mask_i']:getattr(d,n).value=0
    d.rst.value=1;await edge(d);d.rst.value=0
    for rd,rs,hint in [(1,2,1),(0,1,2),(5,1,3),(1,1,1),(2,3,0)]:
        d.src_i.value=0x80001005;d.imm_i.value=0xffc;d.pc_i.value=0x80000020;d.pred_i.value=0x80000024
        d.rd_i.value=rd;d.rs_i.value=rs;d.grant_i.value=1;await edge(d);d.grant_i.value=0;await edge(d)
        assert int(d.resolve_o.value) and int(d.mispredict_o.value)
        assert int(d.target_o.value)==0x80001000 and int(d.link_o.value)==0x80000024
        assert int(d.ras_o.value)==hint and not int(d.exc_o.value)
        await edge(d);assert not int(d.resolve_o.value)
        for _ in range(3):await edge(d);assert int(d.valid_o.value) and int(d.link_o.value)==0x80000024
        d.consume_i.value=1;await edge(d);d.consume_i.value=0
    d.src_i.value=0x80001002;d.imm_i.value=0;d.grant_i.value=1;await edge(d);d.grant_i.value=0;await edge(d)
    # L7b spec 5: IALIGN=16 permits bit1; JALR clears only bit0.
    assert not int(d.exc_o.value) and int(d.resolve_o.value) and int(d.mispredict_o.value)
    assert int(d.target_o.value)==0x80001002 and int(d.link_o.value)==0x80000024
    assert int(d.valid_o.value)
    d.rst.value=1;await edge(d);d.rst.value=0;assert not int(d.valid_o.value)
