import cocotb
from cocotb.triggers import Timer
async def settle(): await Timer(1,unit="ns")
async def edge(d):
    d.clk.value=0;await settle();d.clk.value=1;await settle();d.clk.value=0;await settle()

@cocotb.test()
async def credits_backpressure_and_wake(d):
    for n in ['clk','rsv_i','pair_i','enq_i','enq_pair_i','consume_i','kill_i','correct_i','release_i','data_i','data2_i','mask_i','mask2_i']:getattr(d,n).value=0
    d.rst.value=1;await edge(d);d.rst.value=0
    d.rsv_i.value=1;d.pair_i.value=1;await settle();assert int(d.ready_o.value);await edge(d)
    d.rsv_i.value=0;await settle();assert not int(d.ready_o.value)
    d.enq_i.value=1;d.enq_pair_i.value=1;d.data_i.value=111;d.data2_i.value=222;d.mask2_i.value=1
    await settle();assert int(d.wake_valid_o.value) and int(d.wake_preg_o.value)==33
    await edge(d);d.enq_i.value=0;d.enq_pair_i.value=0
    for _ in range(4):
        await settle();assert int(d.head_valid_o.value) and int(d.data_o.value)==111
        assert int(d.bypass_valid_o.value) and not int(d.wake_valid_o.value)
        await edge(d)
    d.consume_i.value=1;await settle();assert int(d.wake_valid_o.value) and int(d.wake_preg_o.value)==34
    await edge(d);d.consume_i.value=0;await settle();assert int(d.data_o.value)==222
    d.kill_i.value=1;await settle();assert not int(d.head_valid_o.value);await edge(d);d.kill_i.value=0
    await settle();assert not int(d.busy_o.value) and int(d.ready_o.value)
    # C clears branch dependencies; reusing its tag cannot remove this queued result.
    d.rsv_i.value=1;d.pair_i.value=0;await edge(d);d.rsv_i.value=0
    d.enq_i.value=1;d.mask_i.value=1;await edge(d);d.enq_i.value=0
    d.correct_i.value=1;await edge(d);d.correct_i.value=0;d.kill_i.value=1;await settle();assert int(d.head_valid_o.value)
    await edge(d);d.kill_i.value=0;d.consume_i.value=1;await edge(d);d.consume_i.value=0
    # Cancel before enqueue returns reserved pipeline credit without creating a result.
    d.rsv_i.value=1;await edge(d);d.rsv_i.value=0;d.release_i.value=1;await edge(d);d.release_i.value=0
    await settle();assert not int(d.busy_o.value)
    d.rst.value=1;await edge(d);d.rst.value=0;await settle();assert not int(d.head_valid_o.value)
