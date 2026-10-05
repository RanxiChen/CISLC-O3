import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def blocked_load_replays_after_older_store_executes(d):
    for name in ("clk", "mem_valid", "mem_load", "mem_store", "mem_id",
                 "mem_rob", "mem_lq", "mem_sq", "mem_base", "mem_store_data",
                 "mem_branch_mask", "sq_block", "sq_forward", "sq_change",
                 "sq_forward_data", "resolution_valid", "resolution_mispredict",
                 "resolution_tag"):
        getattr(d, name).value = 0
    d.rst.value = 1

    async def tick():
        d.clk.value = 0
        await Timer(5, unit="ns")
        obs = {name: int(getattr(d, name).value) for name in (
            "mem_ready", "replay_busy", "replay_capture", "query_valid",
            "store_execute", "result_valid", "result_id", "result_data")}
        d.clk.value = 1
        await Timer(5, unit="ns")
        return obs

    await tick()
    d.rst.value = 0
    d.mem_valid.value = 1
    d.mem_load.value = 1
    d.mem_id.value = 42
    d.mem_rob.value = 2
    d.mem_lq.value = 1
    d.mem_base.value = 0x80000108
    d.sq_block.value = 1
    obs = await tick()
    assert obs["replay_capture"] == 1 and obs["mem_ready"] == 1, obs
    d.mem_valid.value = 0
    d.mem_load.value = 0
    obs = await tick()
    assert obs["replay_busy"] == 1 and obs["query_valid"] == 1, obs
    obs = await tick()
    assert obs["replay_busy"] == 1 and obs["query_valid"] == 0, obs

    d.mem_valid.value = 1
    d.mem_store.value = 1
    d.mem_rob.value = 1
    d.mem_base.value = 0x80000108
    d.sq_change.value = 1
    obs = await tick()
    assert obs["store_execute"] == 1 and obs["mem_ready"] == 1, obs
    d.mem_valid.value = 0
    d.mem_store.value = 0
    d.sq_change.value = 0
    d.sq_block.value = 0
    d.sq_forward.value = 1
    d.sq_forward_data.value = 0x1122334455667788
    obs = await tick()
    assert obs["replay_busy"] == 1 and obs["query_valid"] == 1, obs
    obs = await tick()
    assert obs["replay_busy"] == 0 and obs["result_valid"] == 1, obs
    assert obs["result_id"] == 42 and obs["result_data"] == 0x1122334455667788, obs


@cocotb.test()
async def wrong_path_replay_is_cancelled(d):
    for name in ("clk", "mem_valid", "mem_load", "mem_store", "mem_id",
                 "mem_rob", "mem_lq", "mem_sq", "mem_base", "mem_store_data",
                 "mem_branch_mask", "sq_block", "sq_forward", "sq_change",
                 "sq_forward_data", "resolution_valid", "resolution_mispredict",
                 "resolution_tag"):
        getattr(d, name).value = 0
    d.rst.value = 1

    async def tick():
        d.clk.value = 0
        await Timer(5, unit="ns")
        obs = (int(d.replay_busy.value), int(d.replay_capture.value),
               int(d.query_valid.value), int(d.result_valid.value))
        d.clk.value = 1
        await Timer(5, unit="ns")
        return obs

    await tick()
    d.rst.value = 0
    d.mem_valid.value = 1
    d.mem_load.value = 1
    d.mem_branch_mask.value = 1
    d.mem_id.value = 5
    d.mem_base.value = 0x80000100
    d.sq_block.value = 1
    assert (await tick())[1] == 1
    d.mem_valid.value = 0
    d.mem_load.value = 0
    d.resolution_valid.value = 1
    d.resolution_mispredict.value = 1
    d.resolution_tag.value = 0
    await tick()
    d.resolution_valid.value = 0
    d.resolution_mispredict.value = 0
    d.sq_change.value = 1
    d.sq_block.value = 0
    d.sq_forward.value = 1
    d.sq_forward_data.value = 0x55
    for _ in range(5):
        assert await tick() == (0, 0, 0, 0)


@cocotb.test()
async def seeded_c_m_replay_pending_response_result_backpressure(d):
    import os,random
    from l3_contract import val,settle,tick
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    inputs=['clk','mem_valid','mem_load','mem_store','mem_id','mem_rob','mem_lq','mem_sq','mem_base','mem_store_data','mem_branch_mask','sq_block','sq_forward','sq_change','sq_forward_data','resolution_valid','resolution_mispredict','resolution_tag','bus_mode_i','dc_ready_i','dc_response_i','dc_response_data_i','result_ready_i','lq_live_i']
    for n in inputs:getattr(d,n).value=0
    d.rst.value=1;await tick(d);d.rst.value=0
    tags=val(d.cfg_tags_o);assert tags>0
    for transaction in range(160):
        for n in inputs:getattr(d,n).value=0
        d.rst.value=1;await tick(d);d.rst.value=0;d.bus_mode_i.value=1;d.lq_live_i.value=1
        ident=transaction+1;data=rng.getrandbits(64);tag=transaction%tags
        mask=(1<<tag)| (1<<((tag+3)%tags));d.mem_branch_mask.value=mask
        d.mem_valid.value=1;d.mem_load.value=1;d.mem_id.value=ident
        d.mem_rob.value=transaction%64;d.mem_lq.value=transaction%16
        d.mem_base.value=0x80010000+8*(transaction%8)
        mode=transaction%3;kill=transaction%4==0
        if mode==0: # Direct forward, C concurrent with creating Result.
            d.sq_forward.value=1;d.sq_forward_data.value=data
            d.resolution_valid.value=1;d.resolution_tag.value=tag
            await tick(d);mask &= ~(1<<tag)
        elif mode==1: # Replay wait awakened by an SQ event, not by timeout.
            d.sq_block.value=1;await settle();assert val(d.replay_capture)==1
            await tick(d);d.mem_valid.value=0;d.mem_load.value=0
            await tick(d)
            for delay in range(rng.randrange(1,6)):
                await tick(d);assert val(d.replay_busy)==1 and val(d.query_valid)==0,(seed,transaction,delay)
            if kill:
                d.resolution_valid.value=1;d.resolution_mispredict.value=1;d.resolution_tag.value=tag
                # Surviving old store must execute while younger replay dies.
                d.mem_valid.value=1;d.mem_store.value=1;d.mem_branch_mask.value=0
                await settle();assert val(d.store_execute)==1
                await tick(d);d.mem_valid.value=0;d.mem_store.value=0
                assert val(d.replay_busy)==0 and val(d.result_valid)==0
                continue
            d.sq_change.value=1;d.sq_block.value=0;d.sq_forward.value=1;d.sq_forward_data.value=data
            d.resolution_valid.value=1;d.resolution_tag.value=tag
            await tick(d);mask &= ~(1<<tag)
            d.resolution_valid.value=0;await tick(d)
        else: # Single pending request; C/M and delayed responses.
            d.dc_ready_i.value=1;await settle();assert val(d.dc_request_o)==1
            await tick(d);d.mem_valid.value=0;d.mem_load.value=0
            assert val(d.pending_o)==1
            # A second load must be backpressured without replacing pending ID.
            d.mem_valid.value=1;d.mem_load.value=1;d.mem_id.value=ident+1000
            await settle();assert val(d.mem_ready)==0
            d.mem_valid.value=0;d.mem_load.value=0
            for delay in range(rng.randrange(1,6)):
                await tick(d);assert val(d.pending_o)==1,(seed,transaction,delay)
            d.resolution_valid.value=1;d.resolution_mispredict.value=kill;d.resolution_tag.value=tag
            await tick(d);mask &= ~(1<<tag)
            d.resolution_valid.value=0;d.dc_response_i.value=1;d.dc_response_data_i.value=data
            if kill:
                # LQ model marks the pending identity dead at the earlier M;
                # the delayed bus response still finishes the request but must
                # never recreate Result after its branch mask was cleared.
                d.lq_live_i.value=0
                await tick(d)
                assert val(d.pending_o)==0 and val(d.result_valid)==0,(seed,transaction,'late young response')
                continue
            await tick(d);d.dc_response_i.value=0
        d.mem_valid.value=0;d.mem_load.value=0;d.resolution_valid.value=0
        assert val(d.result_valid)==1 and val(d.result_id)==ident and val(d.result_data)==data,(seed,transaction,mode)
        for delay in range(rng.randrange(1,6)):
            d.resolution_valid.value=1;d.resolution_tag.value=(tag+3)%tags
            await tick(d);mask &= ~(1<<((tag+3)%tags))
            assert val(d.result_valid)==1 and val(d.result_id)==ident and val(d.result_data)==data
            assert val(d.result_mask_o)==mask,(seed,transaction,delay,mask)
        d.resolution_valid.value=0;d.result_ready_i.value=1;await tick(d)
        assert val(d.result_valid)==0
