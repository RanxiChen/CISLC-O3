"""Public transaction oracle: unbounded allocation order, full response payload.

No access to the RTL rank representation. Slots may complete in any order;
accepted SEND owners remain held through backpressure and WB dependencies.
"""
import os
import random

import cocotb
from l3_contract import clear, codec, field, reset, settle, tick, val

INPUTS = ["clk", "rst", "alloc_i", "alloc_txn_i", "wb_read_done_i", "wb_read_id_i",
          "req_ready_i", "rsp_valid_i", "rsp_i", "install_issue_i",
          "install_done_i", "install_done_id_i"]


@cocotb.test()
async def reordered_owner_release_preserves_send_order_and_held_payload(d):
    rng = random.Random(int(os.getenv("TEST_SEED", "105")))
    await reset(d, INPUTS)
    n = val(d.cfg_n_o)
    owners, held = {}, None
    sequence = allocations = completions = middle_removals = simultaneous = 0
    for cycle in range(2200):
        if cycle in (733, 1466):
            await reset(d, INPUTS)
            owners, held = {}, None
        clear(d, INPUTS)
        free = sorted(set(range(n)) - owners.keys())
        allocate = bool(free) and cycle < 2000 and rng.random() < .8
        done_ids = [i for i, o in owners.items() if o["phase"] == "issued"]
        done = rng.choice(done_ids) if done_ids and rng.random() < .7 else None
        blocked = [i for i, o in owners.items() if o["phase"] == "blocked"]
        wb = rng.choice(blocked) if blocked and rng.random() < .6 else None
        waiting = [i for i, o in owners.items() if o["phase"] == "waiting"]
        response = rng.choice(waiting) if waiting and rng.random() < .7 else None
        data, error = rng.getrandbits(512), int(rng.random() < .1)
        if allocate:
            index = free[0]
            sequence += 1
            new = dict(order=sequence, line=0x2000000 + sequence, getm=rng.randrange(2),
                       phase="blocked" if rng.random() < .3 else "eligible")
            d.alloc_i.value = 1
            d.alloc_txn_i.value = codec(d, "alloc", line_addr=new["line"],
                                        is_getm=new["getm"], wb_wait=int(new["phase"] == "blocked"),
                                        wb_id=index, refill=rng.getrandbits(512))
        d.req_ready_i.value = int(rng.random() < .65)
        if wb is not None:
            d.wb_read_done_i.value = 1
            d.wb_read_id_i.value = wb
        if response is not None:
            d.rsp_valid_i.value = 1
            d.rsp_i.value = codec(d, "rsp", op=val(d.cfg_datae_o), id=response,
                                  error=error, data=data)
        if done is not None:
            d.install_done_i.value = 1
            d.install_done_id_i.value = done
        await settle()
        assert bool(val(d.free_o)) == bool(free)
        assert val(d.free_count_o) == len(free)
        if free:
            assert val(d.free_id_o) == free[0]
        assert bool(val(d.req_valid_o)) == (held is not None), cycle
        eligible = [i for i, o in owners.items() if o["phase"] == "eligible"]
        select = min(eligible, key=lambda i: owners[i]["order"]) if eligible else None
        accepted = held is not None and bool(val(d.req_ready_i))
        if held is not None:
            raw = val(d.req_o)
            assert field(d, "request", raw, "id") == held
            assert field(d, "request", raw, "addr") == owners[held]["line"]
            expected = val(d.cfg_getm_o) if owners[held]["getm"] else val(d.cfg_gets_o)
            assert field(d, "request", raw, "op") == expected
        installable = [i for i, o in owners.items() if o["phase"] == "install"]
        assert bool(val(d.install_valid_o)) == bool(installable)
        install = min(installable) if installable else None
        issue = install is not None and rng.random() < .7
        if install is not None:
            assert val(d.install_id_o) == install
            raw = val(d.install_o)
            assert field(d, "install", raw, "line_addr") == owners[install]["line"]
            assert field(d, "install", raw, "refill") == owners[install]["data"]
            assert field(d, "install", raw, "err") == owners[install]["error"]
        d.install_issue_i.value = int(issue)
        # Selection samples the pre-edge eligible set. A late WB dependency
        # release cannot retarget an already held coherence request.
        next_held = (None if accepted else held) if held is not None else select
        if accepted:
            owners[held]["phase"] = "waiting"
        if wb is not None:
            owners[wb]["phase"] = "eligible"
        if response is not None:
            owners[response].update(phase="install", data=data, error=error)
        if issue:
            owners[install]["phase"] = "issued"
        if done is not None:
            middle_removals += int(any(o["order"] > owners[done]["order"] for o in owners.values()))
            del owners[done]
            completions += 1
        if allocate:
            owners[index] = new
            allocations += 1
            simultaneous += int(done is not None)
        held = next_held
        await tick(d)
    assert not owners and held is None, "all public owners must drain"
    assert allocations > 250 and completions > 200
    assert middle_removals > 30 and simultaneous > 50
