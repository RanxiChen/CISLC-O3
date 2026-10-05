"""F0 32-bit length recognition and block handshake."""
import os
import random

import cocotb
from cocotb.triggers import ReadOnly, Timer
from ifu_f0_model import F0Model, Inputs


def val(signal):
    return int(signal.value)


class Bench:
    def __init__(self, dut, seed):
        self.dut = dut
        self.seed = seed
        self.cycle = 0
        self.model = F0Model(val(dut.cfg_region_bytes_o), len(dut.out_valid_o))

    async def step(self, i):
        d = self.dut
        d.clk_i.value = 0
        d.rst_i.value = int(i.rst)
        d.in_valid_i.value = int(i.valid)
        d.out_ready_i.value = int(i.ready)
        d.region_base_i.value = i.base
        d.block_data_i.value = i.data
        d.ftq_id_i.value = i.ftq_id
        d.entry_slot_i.value = i.entry_slot
        d.cfi_valid_i.value = int(i.cfi_valid)
        d.cfi_slot_i.value = i.cfi_slot
        d.kill_valid_i.value = int(i.kill)
        d.sync_clear_i.value = int(i.sync)
        d.exc_valid_i.value = int(i.exc)
        d.exc_cause_i.value = i.cause
        await Timer(1, unit="ns")
        await ReadOnly()
        ready, instructions = self.model.visible(i)
        context = f"seed={self.seed} cycle={self.cycle} inputs={i}"
        assert val(d.in_ready_o) == ready, context
        mask = sum(1 << slot for slot in instructions)
        assert val(d.out_valid_o) == mask, context
        if i.valid:
            assert val(d.out_brief_id_o) == i.ftq_id, context
        pc_flat = val(d.out_pc_flat_o)
        inst_flat = val(d.out_inst_flat_o)
        len_flat = val(d.out_len_flat_o)
        slot_flat = val(d.out_slot_flat_o)
        id_flat = val(d.out_id_flat_o)
        pc_bits = len(d.region_base_i)
        inst_bits = len(d.block_data_i) // self.model.region_bytes * 4
        slot_bits = len(d.entry_slot_i)
        id_bits = len(d.ftq_id_i)
        for slot, (pc, word, length, ftq_id) in instructions.items():
            raw = (i.data >> (16 * slot)) & 0xffffffff
            fault = i.exc or raw & 3 != 3
            assert (val(d.out_exc_o) >> slot) & 1 == fault, context
            if fault:
                cause = i.cause if i.exc else 2
                tval = pc if i.exc else raw & 0xffff
                assert (val(d.out_cause_flat_o) >> (slot * 6)) & 63 == cause, context
                assert (val(d.out_tval_flat_o) >> (slot * 64)) & ((1 << 64)-1) == tval, context
            assert (pc_flat >> (slot * pc_bits)) & ((1 << pc_bits) - 1) == pc, context
            assert (inst_flat >> (slot * inst_bits)) & ((1 << inst_bits) - 1) == word, context
            assert (len_flat >> (slot * 3)) & 7 == length, context
            assert (slot_flat >> (slot * slot_bits)) & ((1 << slot_bits) - 1) == slot, context
            assert (id_flat >> (slot * id_bits)) & ((1 << id_bits) - 1) == ftq_id, context
        await Timer(1, unit="ns")
        d.clk_i.value = 1
        await Timer(1, unit="ns")
        d.clk_i.value = 0
        self.cycle += 1


@cocotb.test()
async def directed_contract(dut):
    b = Bench(dut, 0)
    block = 0x00400213003001930020011300100093
    await b.step(Inputs(rst=True))
    await b.step(Inputs(valid=True, ready=False, data=block, ftq_id=7))
    await b.step(Inputs(valid=True, ready=True, data=block, ftq_id=7))
    await b.step(Inputs(valid=True, ready=True, data=block, ftq_id=7, entry_slot=2))
    await b.step(Inputs(valid=True, ready=True, data=block, ftq_id=7,
                        cfi_valid=True, cfi_slot=2))
    # An unsupported short encoding must fault, never disappear.
    await b.step(Inputs(valid=True, ready=True, data=block & ~0xffff | 0x0001))
    await b.step(Inputs(valid=True, ready=True, data=block & ~0xffffffff))
    await b.step(Inputs(valid=True, ready=True, data=block, exc=True, cause=1))
    await b.step(Inputs(valid=True, ready=True, data=block, kill=True))
    await b.step(Inputs(valid=True, ready=True, data=block, sync=True))


@cocotb.test()
async def seeded_transactions(dut):
    seed = int(os.environ.get("TEST_SEED", "1"), 0)
    rng = random.Random(seed)
    b = Bench(dut, seed)
    await b.step(Inputs(rst=True))
    for cycle in range(120):
        words = [rng.getrandbits(30) << 2 | rng.choice((1, 3)) for _ in range(4)]
        data = sum(word << (32 * slot) for slot, word in enumerate(words))
        await b.step(Inputs(
            valid=rng.random() < 0.85,
            ready=rng.random() < 0.65,
            base=0x10000000 + cycle * 16,
            data=data,
            ftq_id=cycle & ((1 << len(dut.ftq_id_i)) - 1),
            entry_slot=2 * rng.randrange(4),
            kill=rng.random() < 0.02,
            sync=rng.random() < 0.02,
            exc=rng.random() < 0.1,
        ))
