"""Read-only ROM and exact IO/hole distinction; no old golden updates."""
import cocotb
from l8a_agents import CacheBench, Cpu, OK, ERROR, REPLAY
from test_l8b_dcache import attempt, atomic_req, SC, SWAP


def exception(r, cause, addr):
    assert r["status"] == ERROR
    assert r["exc"] >> 70 == 1
    assert (r["exc"] >> 64) & 63 == cause
    assert r["exc"] & ((1 << 64)-1) == addr


@cocotb.test()
async def rom_load_refill_hit_store_amo_sc_and_ad_write_rejected(d):
    e = CacheBench(d)
    await e.reset()
    for addr in (0x10000000, 0x10010000):
        payload = bytes((i*7+19) & 255 for i in range(64))
        e.mem[addr >> 6] = e.gold[addr >> 6] = int.from_bytes(payload, "little")
        r = await e.load(addr)
        assert r["status"] == OK and r["data"] == int.from_bytes(payload[:8], "little")
        await e.idle()
        before = len(e.events)
        r = await e.load(addr+8)
        assert r["status"] == OK and r["data"] == int.from_bytes(payload[8:16], "little")
        assert len(e.events) == before
        for req in (Cpu(addr, write=True, sta=True),
                    atomic_req(addr, SWAP, 0x1122334455667788), atomic_req(addr, SC, 0)):
            r = await attempt(e, req)
            exception(r, 7, addr)
            assert len(e.events) == before
            assert e.state(addr) != 3 and not int(d.pte_a_write_o.value)
        start = len(e.ad_responses)
        e.ad = (addr, int.from_bytes(payload[:8], "little"), 1, 0, 0)
        await e.until(lambda: len(e.ad_responses) > start)
        assert e.ad_responses[-1][1] & 1  # physical access fault, no CAS write
        assert not int(d.pte_a_write_o.value) and e.state(addr) != 3
        assert len(e.events) == before and e.mem[addr >> 6] == int.from_bytes(payload, "little")
    await e.idle()


@cocotb.test()
async def device_classification_and_holes_return_without_coherent_requests(d):
    e = CacheBench(d)
    await e.reset()
    for addr in (0x02000000, 0x0c000000, 0x12000000, 0x120ffff8):
        before = len(e.events)
        # Ordinary LSU requests are routed to the queue head for MMIO rather
        # than completed by L1D. Observe classification, not a cached load.
        r = (await e.issue(Cpu(addr)))[0]
        assert r["status"] == REPLAY and r["io"] and r["reason"] == 11  # LDW_HEAD
        assert len(e.events) == before
    for addr in (0x02010000, 0x10020000, 0x11010000, 0x12100000, 0x7ffffff8):
        before = len(e.events)
        r = await e.load(addr)
        exception(r, 5, addr)
        assert not r["io"] and len(e.events) == before
