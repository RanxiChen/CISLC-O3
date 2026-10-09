"""Frozen platform permission checks through the real TLB/PTW/A-D path."""
import cocotb
from test_mmu import Tb


def rom_tables(t, root, flags):
    t.put("root_i", root >> 12)
    t.next_table = root + 4096
    return t.map(0x4000, 0x80010000, flags=flags, root=root)


@cocotb.test()
async def rom_page_tables_readable_but_accessed_updates_never_issue(d):
    for root in (0x10000000, 0x10010000):
        for cmd in ("fetch", "load", "store"):
            t = Tb(d)
            await t.reset()
            t.put("adue_i", 1)
            leaf = rom_tables(t, root, 0xcf)
            original = dict(t.mem)
            r = await t.access(0x4000, cmd, "hit")
            assert r["pa"] == 0x80010000 and not r["af"] and not r["pf"]
            assert len(t.reads) == 3 and not t.ad_ops and t.mem == original
            assert root <= leaf < root+65536

            t = Tb(d)
            await t.reset()
            t.put("adue_i", 1)
            leaf = rom_tables(t, root, 0x0f)
            original = dict(t.mem)
            r = await t.access(0x4000, cmd, "af")
            assert not r["pf"] and len(t.reads) == 3
            for _ in range(20):
                await t.tick()
                assert not t.get("ad_req_o")
            assert not t.ad_ops and not t.ad_queue and t.mem == original


@cocotb.test()
async def rom_dirty_update_fault_and_device_or_hole_page_table_read_rejection(d):
    for root in (0x10000000, 0x10010000):
        t = Tb(d)
        await t.reset()
        t.put("adue_i", 1)
        leaf = rom_tables(t, root, 0x4f)
        await t.access(0x4000, "store", "hit")
        original = dict(t.mem)
        t.put("d_va_i", 0x4000)
        t.put("d_commit_i", 1)
        await t.tick()
        t.put("d_commit_i", 0)
        for _ in range(150):
            await t.tick()
            assert not t.get("ad_req_o")
            if t.get("d_commit_done_o"):
                break
        else:
            assert False, "ROM D update failed to return an exception"
        assert t.get("d_commit_exc_o") and not t.ad_ops and t.mem == original
        assert not t.mem[leaf] & 0x80
    for root in (0x02000000, 0x0c000000, 0x12000000, 0x12100000, 0x11010000):
        for cmd in ("fetch", "load", "store"):
            t = Tb(d)
            await t.reset()
            t.put("root_i", root >> 12)
            r = await t.access(0x4000, cmd, "af")
            assert not r["pf"] and not t.reads and not t.ad_ops
