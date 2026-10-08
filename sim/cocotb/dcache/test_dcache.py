"""Existing DCache cases migrated to whole-line coherence and Replay.
Golden byte patterns, load/store addresses and the 24-probe scale are retained.
"""
import os
import random
import cocotb
from l8a_agents import CacheBench, Cpu, BASE, OK, MISS


async def env(dut):
    e=CacheBench(dut)
    await e.reset()
    return e


@cocotb.test()
async def empty_line_recall_pipeline(dut):
    e=await env(dut)
    rng=random.Random(int(os.environ.get('TEST_SEED','1')))
    for cycle in range(24):
        if rng.randrange(3)!=0:
            # Single outstanding SNP replaces the old recall ID pipeline.
            q=await e.probe(BASE+64*cycle)
            assert q['op']==1 and q['dirty']==0 and q['data']==0
        else:
            await e.tick()
    await e.idle()


@cocotb.test()
async def word_banks_refill_store_probe_and_hit_under_miss(dut):
    e=await env(dut)
    line0,line1=0x80000100,0x80000140
    data0=bytes(range(64));data1=bytes((i*3+7)&255 for i in range(64))
    for addr,data in ((line0,data0),(line1,data1)):
        e.mem[addr>>6]=e.gold[addr>>6]=int.from_bytes(data,'little')
    r=await e.load(line0+16)
    assert r['data']==int.from_bytes(data0[16:24],'little')
    e.block_gets=True
    r=(await e.issue(Cpu(line1,ident=2)))[0]
    assert r['status']==MISS
    r=(await e.issue(Cpu(line0+32,ident=3)))[0]
    assert r['status']==OK and r['data']==int.from_bytes(data0[32:40],'little')
    e.block_gets=False
    r=await e.load(line1,ident=2)
    assert r['data']==int.from_bytes(data1[:8],'little')
    replacement=0x8877665544332211
    assert (await e.store(line0+15,replacement,ident=5))['status']==OK
    assert (await e.load(line0+15,ident=4))['data']==replacement
    q=await e.probe(line0)
    expected=bytearray(data0);expected[15:23]=replacement.to_bytes(8,'little')
    assert q['dirty']==1 and q['data']==int.from_bytes(expected,'little')
    assert (await e.load(line0,ident=6))['data']==int.from_bytes(expected[:8],'little')
    await e.idle()


@cocotb.test()
async def dirty_capacity_victim_is_written_back_before_refill(dut):
    e=await env(dut)
    base=0x80000100
    # Retain the original first five lines; add lines for the new eight-way capacity.
    for way in range(e.ways+1):
        line=(base+way*0x1000)>>6
        e.mem[line]=e.gold[line]=0
    await e.store(base+8,0x1122334455667788)
    for way in range(1,e.ways):
        assert (await e.load(base+way*0x1000))['data']==0
    await e.load(base+e.ways*0x1000)
    await e.idle()
    q=next(q for _,q in e.up if q['op']==0 and q['line']==base>>6)
    expected=bytearray(64);expected[8:16]=(0x1122334455667788).to_bytes(8,'little')
    assert q['dirty']==1 and q['data']==int.from_bytes(expected,'little')
    assert (await e.load(base+8))['data']==0x1122334455667788
    await e.idle()


@cocotb.test()
async def byte_enable_all_bank_boundaries_and_line_read_port(dut):
    """Masked PS writes preserve other bytes; probe and CPU share S0 reads."""
    e = await env(dut)
    base = BASE + 0x200
    expected = bytearray(range(64))
    e.mem[base >> 6] = e.gold[base >> 6] = int.from_bytes(expected, 'little')
    await e.load(base)
    for offset in range(57):
        mask = (0x55, 0xaa, 0x81, 0xff)[offset % 4]
        data = bytes((offset * 13 + i * 29) & 255 for i in range(8))
        assert (await e.store(base + offset, int.from_bytes(data, 'little'), mask))['status'] == OK
        for i in range(8):
            if mask >> i & 1:
                expected[offset + i] = data[i]
        # The separate byte oracle also checks untouched bank/way bytes.
        for bank in range(8):
            got = await e.load(base + bank * 8)
            assert got['data'] == int.from_bytes(expected[bank * 8:bank * 8 + 8], 'little')
        if offset % 8 == 7:
            reply = await e.probe(base, down=True)
            assert reply['data'] == int.from_bytes(expected, 'little')
            assert (await e.load(base + 56))['data'] == int.from_bytes(expected[56:64], 'little')
    await e.idle()
