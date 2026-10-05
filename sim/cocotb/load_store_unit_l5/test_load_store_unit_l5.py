import os,random
import cocotb
from cocotb.triggers import Timer
async def settle():await Timer(1,unit='ns')
async def tick(d):
    d.clk.value=0;await settle();d.clk.value=1;await settle();d.clk.value=0;await settle()
@cocotb.test()
async def precise_errors_and_flush_late_response(d):
    inputs=['clk','flush_all_i','dc_error_i','mem_valid','mem_load','mem_store','mem_id','mem_rob','mem_lq','mem_sq','mem_base','mem_store_data','mem_branch_mask','sq_block','sq_forward','sq_change','sq_forward_data','resolution_valid','resolution_mispredict','resolution_tag','bus_mode_i','dc_ready_i','dc_response_i','dc_response_data_i','result_ready_i','lq_live_i']
    rng=random.Random(int(os.getenv('TEST_SEED','1')))
    for transaction in range(150):
        for n in inputs:getattr(d,n).value=0
        d.rst.value=1;await tick(d);d.rst.value=0;d.bus_mode_i.value=1;d.lq_live_i.value=1
        store=transaction%2==0;error=transaction%3==0;flush=transaction%5==0
        addr=0x80010000+transaction*8;rob=transaction%int(d.cfg_rob_o.value)
        d.mem_valid.value=1;d.mem_load.value=not store;d.mem_store.value=store;d.mem_rob.value=rob;d.mem_base.value=addr;d.dc_ready_i.value=1
        await settle();assert int(d.dc_request_o.value)==1 and int(d.mem_ready.value)==1
        assert int(d.store_complete_o.value)==0
        await tick(d);d.mem_valid.value=0;d.dc_ready_i.value=0
        assert int(d.pending_o.value)==1
        if flush:
            d.flush_all_i.value=1;await tick(d);d.flush_all_i.value=0
            assert int(d.pending_o.value)==1
            d.mem_valid.value=1;d.dc_ready_i.value=1;await settle();assert int(d.dc_request_o.value)==0 and int(d.mem_ready.value)==0
            d.mem_valid.value=0
        for _ in range(rng.randrange(1,5)):await tick(d)
        d.dc_response_i.value=1;d.dc_error_i.value=error;d.dc_response_data_i.value=rng.getrandbits(64);await settle()
        assert int(d.exc_valid_o.value)==(error and not flush)
        if error and not flush:
            assert int(d.exc_cause_o.value)==(7 if store else 5)
            assert int(d.exc_tval_o.value)==addr and int(d.exc_rob_o.value)==rob
        assert int(d.store_complete_o.value)==(store and not error and not flush)
        await tick(d);d.dc_response_i.value=0;await settle()
        assert int(d.result_valid.value)==(not store and not error and not flush)
        assert int(d.pending_o.value)==0
