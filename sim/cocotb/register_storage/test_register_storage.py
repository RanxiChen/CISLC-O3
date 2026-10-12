"""Architectural scoreboards; never read DUT internal storage or ready bits."""
import random
import cocotb
from cocotb.triggers import Timer

async def settle():
    await Timer(1, unit="ns")

async def edge(d):
    d.clk.value = 0
    await settle()
    d.clk.value = 1
    await settle()
    d.clk.value = 0
    await settle()

def pack(values, width):
    return sum(value << (i * width) for i, value in enumerate(values))

@cocotb.test()
async def storage_bypass_allocation_and_write_precedence(d):
    await settle()
    rng = random.Random(105)
    dims = {name: int(getattr(d, name+"_o").value) for name in ["ir", "fr", "iw", "fw", "aw", "ni", "nf", "preg_w"]}
    for name in ["clk", "int_wr_en_i", "fp_wr_en_i", "int_alloc_valid_i", "fp_alloc_valid_i", "int_rd_addr_i", "fp_rd_addr_i", "int_wr_addr_i", "fp_wr_addr_i", "int_wr_data_i", "fp_wr_data_i", "int_alloc_preg_i", "fp_alloc_preg_i"]:
        getattr(d, name).value = 0
    d.rst.value = 1
    await edge(d)
    d.rst.value = 0
    ready = {dom: [(i < 32) for i in range(dims[n])] for dom, n in [("int", "ni"), ("fp", "nf")]}
    data = {"int": {}, "fp": {}}
    # Initialise every architectural/physical data entry through actual writes;
    # FPGA reset deliberately has no promise of zero for unwritten RAM words.
    for cycle in range(max(dims["ni"], dims["nf"])):
        for dom, n in [("int", "ni"), ("fp", "nf")]:
            enable = cycle < dims[n]
            getattr(d, dom+"_wr_en_i").value = int(enable)
            getattr(d, dom+"_wr_addr_i").value = cycle if enable else 0
            value = rng.getrandbits(64)
            getattr(d, dom+"_wr_data_i").value = value
            if enable:
                data[dom][cycle] = 0 if dom == "int" and cycle == 0 else value
                ready[dom][cycle] = True
        await edge(d)
    for cycle in range(700):
        updates = {}
        for dom, rp, wp, size in [("int", "ir", "iw", "ni"), ("fp", "fr", "fw", "nf")]:
            count = dims[size]
            addrs = [rng.randrange(count) for _ in range(dims[wp])]
            if cycle % 9 == 0: addrs = [cycle % count] * dims[wp]  # duplicate writes: highest port wins
            enables = [rng.randrange(2) for _ in addrs]
            words = [rng.getrandbits(64) for _ in addrs]
            alloc = [rng.randrange(count) for _ in range(dims["aw"])]
            active = [rng.randrange(2) for _ in alloc]
            alloc[0] = addrs[0]
            active[0] = 1
            reads = [addrs[i % len(addrs)] if i < len(addrs) else rng.randrange(count) for i in range(dims[rp])]
            if cycle % 5 == 0: reads[0] = 0  # INT p0 fixed zero; FP p0 ordinary storage
            getattr(d, dom+"_wr_en_i").value = pack(enables, 1)
            getattr(d, dom+"_wr_addr_i").value = pack(addrs, dims["preg_w"])
            getattr(d, dom+"_wr_data_i").value = pack(words, 64)
            getattr(d, dom+"_alloc_valid_i").value = pack(active, 1)
            getattr(d, dom+"_alloc_preg_i").value = pack(alloc, dims["preg_w"])
            getattr(d, dom+"_rd_addr_i").value = pack(reads, dims["preg_w"])
            expected = dict(data[dom])
            next_ready = list(ready[dom])
            for on, addr in zip(active, alloc):
                if on: next_ready[addr] = False
            for on, addr, word in zip(enables, addrs, words):
                if on:
                    next_ready[addr] = True
                    if dom != "int" or addr != 0: expected[addr] = word
            updates[dom] = expected, next_ready, reads
        await settle()
        for dom, (expected, _, reads) in updates.items():
            assert int(getattr(d, dom+"_rd_data_o").value) == pack([expected[a] for a in reads], 64), (cycle, dom, reads)
            assert int(getattr(d, dom+"_ready_o").value) == pack(ready[dom], 1), (cycle, dom, "pre-edge readiness changed")
        await edge(d)
        for dom, (expected, next_ready, reads) in updates.items():
            data[dom], ready[dom] = expected, next_ready
            assert int(getattr(d, dom+"_ready_o").value) == pack(ready[dom], 1), (cycle, dom, "write must win allocation")
            assert int(getattr(d, dom+"_rd_data_o").value) == pack([expected[a] for a in reads], 64)
