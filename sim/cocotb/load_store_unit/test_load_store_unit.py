import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def blocked_load_replays_after_older_store_executes(d):
    for name in ("clk", "mem_valid", "mem_load", "mem_store", "mem_id",
                 "mem_rob", "mem_lq", "mem_sq", "mem_base", "mem_store_data",
                 "sq_block", "sq_forward", "sq_change", "sq_forward_data"):
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
