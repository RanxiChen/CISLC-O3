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
                 "commit_idx", "dc_req_ready", "dc_resp_valid", "dc_resp_idx"):
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
