import cocotb
from cocotb.triggers import Timer
async def settle(): await Timer(1,unit="ns")
async def edge(d):
    d.clk.value=0;await settle();d.clk.value=1;await settle();d.clk.value=0;await settle()

@cocotb.test()
async def promise_to_select_before_prf_and_late_consumer(d):
    d.clk.value=0;d.launch_i.value=0;d.enq_i.value=0;d.wb_ready_i.value=0;d.rst.value=1
    await edge(d);d.rst.value=0;d.enq_i.value=1;await edge(d);d.enq_i.value=0
    assert not int(d.issue_o.value)
    d.launch_i.value=1;await edge(d);d.launch_i.value=0
    for _ in range(8):
        await settle()
        if int(d.wake_o.value):break
        assert not int(d.issue_o.value);await edge(d)
    else:assert False,'no early wake'
    assert not int(d.bypass_o.value) and not int(d.written_o.value)
    await edge(d)
    assert int(d.issue_o.value) and int(d.bypass_o.value) and not int(d.written_o.value)
    await edge(d);assert int(d.issued_o.value) and int(d.operand_o.value)==63
    # WB still blocked. A consumer arriving after the original promise is woken by head visibility.
    d.enq_i.value=1;await edge(d);d.enq_i.value=0
    assert int(d.issue_o.value) and not int(d.written_o.value)
    await edge(d);assert int(d.issued_o.value) and int(d.operand_o.value)==63
    # Head leaves exactly at the PRF write edge; next consumer reads the written value.
    d.wb_ready_i.value=1;await edge(d);d.wb_ready_i.value=0
    assert int(d.written_o.value) and not int(d.bypass_o.value)
    d.enq_i.value=1;await edge(d);d.enq_i.value=0;await edge(d)
    assert int(d.issued_o.value) and int(d.operand_o.value)==63
