import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def youngest_complete_store_and_unknown_address(d):
    d.clk.value = 0
    d.rst.value = 1
    d.alloc_valid.value = 0
    d.alloc_rob.value = 0
    d.execute_valid.value = 0
    d.execute_idx.value = 0
    d.execute_addr.value = 0
    d.execute_data.value = 0
    d.execute_mask.value = 0
    d.query_valid.value = 0
    d.query_rob.value = 0
    d.query_addr.value = 0
    d.query_mask.value = 0
    d.commit_valid.value = 0
    d.commit_idx.value = 0
    d.dc_req_ready.value = 0
    d.dc_resp_valid.value = 0
    d.dc_resp_idx.value = 0
    d.local_drain_ready.value = 0

    async def tick():
        d.clk.value = 0
        await Timer(5, unit="ns")
        d.clk.value = 1
        await Timer(5, unit="ns")

    async def alloc(rob):
        d.alloc_valid.value = 1
        d.alloc_rob.value = rob
        await Timer(1, unit="ns")
        idx = int(d.alloc_idx.value)
        await tick()
        d.alloc_valid.value = 0
        return idx

    async def execute(idx, addr, data, mask):
        d.execute_valid.value = 1
        d.execute_idx.value = idx
        d.execute_addr.value = addr
        d.execute_data.value = data
        d.execute_mask.value = mask
        await tick()
        d.execute_valid.value = 0

    async def query(rob, addr, mask):
        d.query_valid.value = 1
        d.query_rob.value = rob
        d.query_addr.value = addr
        d.query_mask.value = mask
        await Timer(1, unit="ns")
        return (int(d.query_block.value), int(d.query_forward_valid.value),
                int(d.query_forward_data.value))

    await tick()
    d.rst.value = 0
    old = await alloc(1)
    middle = await alloc(2)
    young = await alloc(3)
    assert (await query(4, 0x100, 0x0F))[:2] == (1, 0)
    await execute(middle, 0x102, 0x88776655, 0x03)
    await execute(young, 0x100, 0x44332211, 0x0F)
    # B32: an unknown older address still blocks even after a later full write.
    assert (await query(4, 0x100, 0x0F))[:2] == (1, 0)
    await execute(old, 0x200, 0xDEADBEEF, 0x0F)
    assert await query(4, 0x100, 0x0F) == (0, 1, 0x44332211)
    # A partial younger store cannot be combined with the older full write.
    tail = await alloc(5)
    await execute(tail, 0x101, 0x99, 0x01)
    assert (await query(6, 0x100, 0x0F))[:2] == (1, 0)
    # The same store is younger than ROB 4 and must not affect its load.
    assert await query(4, 0x100, 0x0F) == (0, 1, 0x44332211)


@cocotb.test()
async def committed_store_waits_for_dcache_completion(d):
    for name in ("clk", "alloc_valid", "alloc_rob", "execute_valid", "execute_idx",
                 "execute_addr", "execute_data", "execute_mask", "query_valid",
                 "query_rob", "query_addr", "query_mask", "commit_valid",
                 "commit_idx", "dc_req_ready", "dc_resp_valid", "dc_resp_idx",
                 "local_drain_ready"):
        getattr(d, name).value = 0
    d.rst.value = 1

    async def tick():
        d.clk.value = 0
        await Timer(5, unit="ns")
        obs = (int(d.dc_req_valid.value), int(d.dc_req_idx.value),
               int(d.dc_req_addr.value), int(d.committed_empty.value))
        d.clk.value = 1
        await Timer(5, unit="ns")
        return obs

    await tick()
    d.rst.value = 0
    d.alloc_valid.value = 1
    d.alloc_rob.value = 1
    idx = int(d.alloc_idx.value)
    await tick()
    d.alloc_valid.value = 0
    d.execute_valid.value = 1
    d.execute_idx.value = idx
    d.execute_addr.value = 0x80000204
    d.execute_data.value = 0x11223344
    d.execute_mask.value = 0x0F
    await tick()
    d.execute_valid.value = 0
    d.commit_valid.value = 1
    d.commit_idx.value = idx
    await tick()
    d.commit_valid.value = 0
    assert (await tick()) == (1, idx, 0x80000204, 0)
    d.dc_req_ready.value = 1
    assert (await tick())[0] == 1
    d.dc_req_ready.value = 0
    assert (await tick())[0] == 0  # no duplicate while accepted request is outstanding
    d.dc_resp_valid.value = 1
    d.dc_resp_idx.value = idx + 1
    await tick()
    assert (await tick())[3] == 0  # wrong identity cannot release the SQ head
    d.dc_resp_idx.value = idx
    await tick()
    d.dc_resp_valid.value = 0
    assert (await tick())[3] == 1


@cocotb.test()
async def committed_dtcm_store_uses_local_drain(d):
    for name in ("clk", "alloc_valid", "alloc_rob", "execute_valid", "execute_idx",
                 "execute_addr", "execute_data", "execute_mask", "query_valid",
                 "query_rob", "query_addr", "query_mask", "commit_valid",
                 "commit_idx", "dc_req_ready", "dc_resp_valid", "dc_resp_idx",
                 "local_drain_ready"):
        getattr(d, name).value = 0
    d.rst.value = 1

    async def tick():
        d.clk.value = 0
        await Timer(5, unit="ns")
        obs = (int(d.local_drain_valid.value), int(d.dc_req_valid.value),
               int(d.committed_empty.value))
        d.clk.value = 1
        await Timer(5, unit="ns")
        return obs

    await tick()
    d.rst.value = 0
    d.alloc_valid.value = 1
    d.alloc_rob.value = 1
    idx = int(d.alloc_idx.value)
    await tick()
    d.alloc_valid.value = 0
    d.execute_valid.value = 1
    d.execute_idx.value = idx
    d.execute_addr.value = 0x11000008
    d.execute_data.value = 0x55
    d.execute_mask.value = 0xff
    await tick()
    d.execute_valid.value = 0
    d.commit_valid.value = 1
    d.commit_idx.value = idx
    await tick()
    d.commit_valid.value = 0
    assert (await tick()) == (1, 0, 0)
    d.local_drain_ready.value = 1
    assert (await tick()) == (1, 0, 0)
    d.local_drain_ready.value = 0
    assert (await tick()) == (0, 0, 1)


@cocotb.test()
async def four_store_commit_and_recovery_old_execute_drain_random_delays(d):
    import os,random
    from l3_contract import val,settle,tick,array
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    scalar=['clk','alloc_valid','alloc_rob','execute_valid','execute_idx','execute_addr','execute_data','execute_mask','query_valid','query_rob','query_addr','query_mask','commit_valid','commit_idx','dc_req_ready','dc_resp_valid','dc_resp_idx','local_drain_ready','multi_mode_i','multi_alloc_count_i','multi_commit_count_i','resolution_valid_i','resolution_mispredict_i','resolution_tag_i','restore_tail_i']
    for n in scalar:getattr(d,n).value=0
    array(d.multi_rob_i,[0]*len(d.multi_rob_i));array(d.multi_mask_i,[0]*len(d.multi_mask_i));array(d.multi_commit_idx_i,[0]*len(d.multi_commit_idx_i))
    d.rst.value=1;await tick(d);d.rst.value=0;await settle()
    w=val(d.cfg_width_o);depth=val(d.cfg_depth_o);assert w==4
    # Every batch is independent and exercises four-lane identity/wrap; some
    # batches recover while older store0 executes and commits.
    for batch in range(80):
        d.multi_mode_i.value=1;d.multi_alloc_count_i.value=w
        array(d.multi_rob_i,[(batch*w+n)%64 for n in range(w)])
        kill=batch%2==0
        array(d.multi_mask_i,[0,0,1,1] if kill else [0]*w)
        await settle();ids=[val(d.multi_alloc_idx_o[n]) for n in range(w)]
        assert len(set(ids))==w
        await tick(d);d.multi_alloc_count_i.value=0
        if kill:
            d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=1;d.resolution_tag_i.value=0
            d.restore_tail_i.value=(ids[1]+1)%depth
        # Old execute and commit survive the M edge, remaining old store
        # executes next; C interleaves ordinary execute and multi commit.
        count=2 if kill else w
        for n in range(count):
            d.execute_valid.value=1;d.execute_idx.value=ids[n]
            d.execute_addr.value=0x80010000+8*n;d.execute_data.value=batch*10+n;d.execute_mask.value=0xff
            if n==0:
                d.multi_commit_count_i.value=1;d.multi_commit_idx_i[0].value=ids[0]
            else:d.multi_commit_count_i.value=0
            await tick(d)
            d.resolution_valid_i.value=0;d.resolution_mispredict_i.value=0
        d.execute_valid.value=0
        d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=0;d.resolution_tag_i.value=1
        d.multi_commit_count_i.value=count
        array(d.multi_commit_idx_i,ids[:count]+[0]*(w-count))
        await tick(d);d.multi_commit_count_i.value=0;d.resolution_valid_i.value=0
        for n in range(count):
            for delay in range(rng.randrange(1,6)):
                await settle();assert val(d.dc_req_valid)==1,(seed,batch,n,delay)
                assert val(d.dc_req_idx)==ids[n]
                assert val(d.dc_req_addr)==0x80010000+8*n
                await tick(d)
            d.dc_req_ready.value=1;await tick(d);d.dc_req_ready.value=0
            # Request handshake does not release SQ; response does.
            before=val(d.free_count_o)
            for _ in range(rng.randrange(1,5)):
                await tick(d);assert val(d.free_count_o)==before,(seed,batch,n)
                assert val(d.dc_req_valid)==0
            d.dc_resp_valid.value=1;d.dc_resp_idx.value=ids[n]
            # Every response can coincide with a correct resolve, and M keeps
            # already committed stores even while draining completes.
            d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=(n==0 and kill)
            d.resolution_tag_i.value=0;d.restore_tail_i.value=(ids[count-1]+1)%depth
            await tick(d);d.dc_resp_valid.value=0;d.resolution_valid_i.value=0;d.resolution_mispredict_i.value=0
            assert val(d.free_count_o)==before+1,(seed,batch,n)
            # Duplicate response cannot release the next store.
            d.dc_resp_valid.value=1;await tick(d);d.dc_resp_valid.value=0
            assert val(d.free_count_o)==before+1,(seed,batch,n,'duplicate')
        assert val(d.free_count_o)==depth and val(d.committed_empty)==1,(seed,batch)
