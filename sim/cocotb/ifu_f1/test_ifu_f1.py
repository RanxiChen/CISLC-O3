"""F1 fetch_entry_t fields and no-predecode-correction contract."""
import os
import random

import cocotb
from cocotb.triggers import ReadOnly, Timer
from ifu_f1_model import Inputs, visible


def val(signal):
    return int(signal.value)


def pack(values, bits):
    return sum(value << (index * bits) for index, value in enumerate(values))


class Bench:
    def __init__(self, dut, seed):
        self.dut = dut
        self.seed = seed
        self.cycle = 0
        self.width = val(dut.cfg_f1_width_o)

    async def step(self, i):
        d = self.dut
        d.clk_i.value = 0
        d.rst_i.value = int(i.rst)
        d.in_valid_i.value = i.valid_mask
        d.in_pc_flat_i.value = pack(i.pcs, len(d.brief_next_pc_i))
        d.in_inst_flat_i.value = pack(i.instructions, len(d.in_inst_flat_i) // len(i.pcs))
        d.in_id_flat_i.value = pack(i.ids, len(d.in_id_flat_i) // len(i.ids))
        d.brief_cfi_valid_i.value = int(i.cfi_valid)
        d.brief_cfi_slot_i.value = i.cfi_slot
        d.brief_raw_taken_i.value = int(i.raw_taken)
        d.brief_next_pc_i.value = i.next_pc
        d.out_ready_i.value = int(i.ready)
        d.kill_valid_i.value = int(i.kill)
        await Timer(1, unit="ns")
        await ReadOnly()
        ready, output = visible(i, self.width)
        context = f"seed={self.seed} cycle={self.cycle} inputs={i}"
        mask = (1 << len(output)) - 1
        assert val(d.in_ready_o) == ready, context
        assert val(d.out_valid_o) == mask and val(d.entry_valid_o) == mask, context
        assert val(d.predecode_valid_o) == 0, context
        pc_bits = len(d.brief_next_pc_i)
        word_bits = len(d.in_inst_flat_i) // len(i.instructions)
        id_bits = len(d.in_id_flat_i) // len(i.ids)
        slot_bits = len(d.brief_cfi_slot_i)
        for lane, expected in enumerate(output):
            assert val(d.out_pc_flat_o) >> (lane * pc_bits) & ((1 << pc_bits)-1) == expected["pc"], context
            assert val(d.out_next_flat_o) >> (lane * pc_bits) & ((1 << pc_bits)-1) == expected["next_pc"], context
            assert val(d.out_inst_flat_o) >> (lane * word_bits) & ((1 << word_bits)-1) == expected["instruction"], context
            assert val(d.out_raw_flat_o) >> (lane * word_bits) & ((1 << word_bits)-1) == expected["instruction"], context
            assert val(d.out_id_flat_o) >> (lane * id_bits) & ((1 << id_bits)-1) == expected["ftq_id"], context
            assert val(d.out_slot_flat_o) >> (lane * slot_bits) & ((1 << slot_bits)-1) == expected["slot"], context
            assert bool(val(d.ftq_last_o) & (1 << lane)) == expected["last"], context
            assert bool(val(d.pred_taken_o) & (1 << lane)) == expected["taken"], context
        await Timer(1, unit="ns")
        d.clk_i.value = 1
        await Timer(1, unit="ns")
        d.clk_i.value = 0
        self.cycle += 1


@cocotb.test()
async def directed_contract(dut):
    b = Bench(dut, 0)
    pcs = tuple(0x10000000 + slot * 2 for slot in range(8))
    words = (0x00100093, 0, 0x00200113, 0, 0x00300193, 0, 0x00400213, 0)
    ids = (5,) * 8
    await b.step(Inputs(rst=True))
    await b.step(Inputs(valid_mask=0x55, pcs=pcs, instructions=words,
                        ids=ids, ready=False))
    await b.step(Inputs(valid_mask=0x55, pcs=pcs, instructions=words,
                        ids=ids, ready=True))
    await b.step(Inputs(valid_mask=0x14, pcs=pcs, instructions=words,
                        ids=ids, ready=True))
    await b.step(Inputs(valid_mask=0x55, pcs=pcs, instructions=words,
                        ids=ids, ready=True, cfi_valid=True, cfi_slot=6,
                        raw_taken=True, next_pc=0x20000000))
    await b.step(Inputs(valid_mask=0x55, pcs=pcs, instructions=words,
                        ids=ids, ready=True, kill=True))


@cocotb.test()
async def seeded_transactions(dut):
    seed = int(os.environ.get("TEST_SEED", "1"), 0)
    rng = random.Random(seed)
    b = Bench(dut, seed)
    await b.step(Inputs(rst=True))
    for cycle in range(120):
        slots = rng.sample(range(8), rng.randrange(5))
        mask = sum(1 << slot for slot in slots)
        pcs = tuple(0x10000000 + 16*cycle + 2*slot for slot in range(8))
        words = tuple((rng.getrandbits(30) << 2) | 3 for _ in range(8))
        ids = (cycle & ((1 << (len(dut.in_id_flat_i)//8))-1),) * 8
        await b.step(Inputs(
            valid_mask=mask, pcs=pcs, instructions=words, ids=ids,
            ready=rng.random() < 0.7,
            kill=rng.random() < 0.02,
            cfi_valid=rng.random() < 0.2,
            cfi_slot=rng.randrange(8),
            raw_taken=rng.random() < 0.5,
            next_pc=0x20000000 + 16*cycle,
        ))
