"""uBTB public-port tests: each step checks both sides of the rising edge."""

import os
import random
from dataclasses import dataclass

import cocotb
from cocotb.triggers import ReadOnly, Timer

from ubtb_model import (
    CFI_BR, CFI_JAL, CFI_JALR, Inputs, Prediction, RAS_POP, RAS_PUSH,
    Train, UbtbModel,
)


def value(signal) -> int:
    return int(signal.value)


@dataclass(frozen=True)
class Observed:
    hit: bool
    ready: bool
    pred: Prediction
    lookup_inc: int
    hit_inc: int


class Bench:
    def __init__(self, dut, seed: int) -> None:
        self.dut = dut
        self.seed = seed
        self.cycle = 0
        self.model = UbtbModel(
            vaddr_bits=len(dut.lookup_pc_i),
            region_bytes=value(dut.cfg_region_bytes_o),
            entries=value(dut.cfg_entries_o),
            tag_bits=value(dut.cfg_tag_bits_o),
            slots=len(dut.train_br_commit_mask_i),
        )

    def drive(self, inputs: Inputs) -> None:
        d = self.dut
        t = inputs.train
        d.clk_i.value = 0
        d.rst_i.value = int(inputs.rst)
        d.lookup_valid_i.value = int(inputs.query_valid)
        d.lookup_pc_i.value = inputs.query_pc
        d.stall_i.value = int(inputs.stall)
        d.train_valid_i.value = int(t.valid)
        d.train_region_base_i.value = t.pc
        d.train_br_commit_mask_i.value = t.br_commit_mask
        d.train_br_taken_mask_i.value = t.br_taken_mask
        d.train_cfi_valid_i.value = int(t.cfi_valid)
        d.train_cfi_slot_i.value = t.cfi_slot
        d.train_cfi_type_i.value = t.cfi_type
        d.train_ras_action_i.value = t.ras_action
        d.train_cfi_target_i.value = t.target

    def observe(self) -> Observed:
        d = self.dut
        return Observed(
            hit=bool(value(d.hit_o)),
            ready=bool(value(d.train_ready_o)),
            pred=Prediction(
                region_base=value(d.pred_region_base_o),
                entry_slot=value(d.pred_entry_slot_o),
                br_mask=value(d.pred_br_mask_o),
                jal_mask=value(d.pred_jal_mask_o),
                cfi_valid=bool(value(d.pred_cfi_valid_o)),
                cfi_slot=value(d.pred_cfi_slot_o),
                cfi_type=value(d.pred_cfi_type_o),
                ras_action=value(d.pred_ras_action_o),
                raw_pred_taken=bool(value(d.pred_raw_pred_taken_o)),
                target_missing=bool(value(d.pred_target_missing_o)),
                target=value(d.pred_cfi_target_o),
                next_pc=value(d.pred_next_pc_o),
            ),
            lookup_inc=value(d.perf_lookup_o),
            hit_inc=value(d.perf_hit_o),
        )

    def check(self, actual: Observed, inputs: Inputs, phase: str) -> None:
        hit, ready, pred, lookup_inc, hit_inc = self.model.visible(inputs)
        expected = Observed(hit, ready, pred, lookup_inc, hit_inc)
        assert int(self.dut.reserved_rvc_o.value) == 0
        assert int(self.dut.reserved_edge_o.value) == 0
        context = f"seed={self.seed} cycle={self.cycle} {phase} inputs={inputs}"
        assert actual == expected, f"{context}: got={actual}, expected={expected}"

    async def step(self, inputs: Inputs) -> tuple[Observed, Observed]:
        # Cycle N combinational: changing PC/stall/reset changes output without
        # waiting for a clock edge. Training has not changed the table yet.
        self.drive(inputs)
        await Timer(1, unit="ns")
        await ReadOnly()
        before = self.observe()
        self.check(before, inputs, "before edge")

        # Rising edge: BPU would sample the old prediction while committed
        # training updates the table. Then the same still-driven query sees new.
        await Timer(1, unit="ns")
        self.dut.clk_i.value = 1
        self.model.tick(inputs)
        await Timer(1, unit="ns")
        await ReadOnly()
        after = self.observe()
        self.check(after, inputs, "after edge")
        await Timer(1, unit="ns")
        self.dut.clk_i.value = 0
        self.cycle += 1
        return before, after


async def new_bench(dut, seed: int) -> Bench:
    dut.clk_i.value = 0
    await Timer(1, unit="ns")
    b = Bench(dut, seed)
    await b.step(Inputs(rst=True, query_valid=True,
                        train=Train(valid=True, pc=0x1000, cfi_valid=True,
                                    cfi_type=CFI_JAL, target=0x9000)))
    await b.step(Inputs(rst=True))
    return b


@cocotb.test()
async def directed_contract(dut):
    b = await new_bench(dut, 0)
    a = 0x1000
    region = b.model.region_bytes
    target = 0x8000_2000

    _, out = await b.step(Inputs(query_valid=True, query_pc=a + 2))
    assert not out.hit and out.pred.entry_slot == 1
    assert out.pred.next_pc == a + region and out.lookup_inc == 1

    # U18: a new region containing only committed NT BRs must not allocate.
    await b.step(Inputs(train=Train(valid=True, pc=a, br_commit_mask=1 << 3)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert not out.hit and out.pred.br_mask == 0
    assert not out.pred.cfi_valid and out.hit_inc == 0

    # First taken BR installs weak-taken; a later entry may not jump backwards
    # to an owner slot that lies before its own entry slot.
    await b.step(Inputs(train=Train(valid=True, pc=a, cfi_valid=True,
                                    cfi_slot=3, cfi_type=CFI_BR, target=target)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert out.pred.cfi_valid and out.pred.next_pc == target
    _, out = await b.step(Inputs(query_valid=True, query_pc=a + 8))
    assert out.hit and not out.pred.cfi_valid and out.pred.next_pc == a + region

    # Same owner taken saturates up; committed NT occurrences saturate down.
    await b.step(Inputs(train=Train(valid=True, pc=a, cfi_valid=True,
                                    cfi_slot=3, cfi_type=CFI_BR, target=target + 4)))
    for _ in range(3):
        await b.step(Inputs(train=Train(valid=True, pc=a, br_commit_mask=1 << 3)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert not out.pred.cfi_valid and out.pred.next_pc == a + region
    await b.step(Inputs(train=Train(valid=True, pc=a, br_commit_mask=1 << 2)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert out.pred.br_mask == (1 << 2 | 1 << 3)
    assert not out.pred.cfi_valid, "other BR must not train the owner counter"
    await b.step(Inputs(train=Train(valid=True, pc=a, cfi_valid=True,
                                    cfi_slot=3, cfi_type=CFI_BR, target=target)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert not out.pred.cfi_valid, "one taken only raises strong NT to weak NT"
    await b.step(Inputs(train=Train(valid=True, pc=a, cfi_valid=True,
                                    cfi_slot=3, cfi_type=CFI_BR, target=target)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert out.pred.cfi_valid

    # A new target owner resets BR confidence; JAL/JALR are unconditional.
    await b.step(Inputs(train=Train(valid=True, pc=a, cfi_valid=True,
                                    cfi_slot=5, cfi_type=CFI_JAL,
                                    ras_action=RAS_PUSH, target=0xA000)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert out.pred.jal_mask == 1 << 5 and out.pred.ras_action == RAS_PUSH
    assert out.pred.next_pc == 0xA000
    await b.step(Inputs(train=Train(valid=True, pc=a, cfi_valid=True,
                                    cfi_slot=6, cfi_type=CFI_JALR,
                                    ras_action=RAS_POP, target=0xB000)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert out.pred.jal_mask == 1 << 5 and out.pred.cfi_type == CFI_JALR
    assert out.pred.ras_action == RAS_POP and out.pred.next_pc == 0xB000

    # Unlike the registered main BTB, a combinational query changes at the
    # training edge: before = old target, after = new target.
    before, after = await b.step(Inputs(query_valid=True, query_pc=a,
                                        train=Train(valid=True, pc=a,
                                                    cfi_valid=True, cfi_slot=6,
                                                    cfi_type=CFI_JALR,
                                                    target=0xC000)))
    assert before.pred.next_pc == 0xB000 and after.pred.next_pc == 0xC000
    _, out = await b.step(Inputs(query_valid=True, query_pc=a, stall=True,
                                 train=Train(valid=True, pc=a, cfi_valid=True,
                                             cfi_slot=6, cfi_type=CFI_JALR,
                                             target=0xD000)))
    assert out.pred == Prediction() and not out.hit
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert out.pred.next_pc == 0xD000, "stall must not block training"

    # Empty/no-op packets cannot fill the table; a complete table replaces
    # one entry at a time and reset invalidates all of them.
    await b.step(Inputs(rst=True))
    await b.step(Inputs(train=Train(valid=True, pc=a)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert not out.hit
    bases = [0x5000 + n * region for n in range(b.model.entries + 1)]
    assert len({b.model.tag_of(pc) for pc in bases}) == len(bases)
    for n, pc in enumerate(bases):
        await b.step(Inputs(train=Train(valid=True, pc=pc, cfi_valid=True,
                                        cfi_type=CFI_JAL, target=0x9000 + n * 16)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=bases[0]))
    assert not out.hit, "full-table round-robin must evict the oldest fill"
    for pc in bases[1:]:
        _, out = await b.step(Inputs(query_valid=True, query_pc=pc))
        assert out.hit

    # Two different region numbers can alias through the documented folded tag.
    await b.step(Inputs(rst=True))
    alias = a ^ (1 << b.model.shift) ^ (1 << (b.model.shift + b.model.tag_bits))
    assert a != alias and b.model.tag_of(a) == b.model.tag_of(alias)
    await b.step(Inputs(train=Train(valid=True, pc=a, cfi_valid=True,
                                    cfi_type=CFI_JAL, target=0xE000)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=alias))
    assert out.hit and out.pred.next_pc == 0xE000
    await b.step(Inputs(rst=True))
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert not out.hit


@cocotb.test()
async def seeded_transactions(dut):
    seed = int(os.environ.get("TEST_SEED", "1"), 0)
    dut._log.info("uBTB randomized seed=%d", seed)
    b = await new_bench(dut, seed)
    rng = random.Random(seed)
    region = b.model.region_bytes
    bases = [0x2000 + n * region for n in range(b.model.entries * 2)]
    bases += [pc ^ (1 << b.model.shift) ^
              (1 << (b.model.shift + b.model.tag_bits)) for pc in bases[:8]]

    for _ in range(600):
        pc = rng.choice(bases)
        train_pc = rng.choice(bases)
        slot = rng.randrange(b.model.slots)
        kind = rng.choice((CFI_BR, CFI_JAL, CFI_JALR))
        train = Train(
            valid=rng.random() < 0.48,
            pc=train_pc,
            br_commit_mask=(1 << rng.randrange(b.model.slots))
            if rng.random() < 0.55 else 0,
            br_taken_mask=(1 << slot) if kind == CFI_BR else 0,
            cfi_valid=rng.random() < 0.48,
            cfi_slot=slot,
            cfi_type=kind,
            ras_action=rng.randrange(3),
            target=(0x8000_0000 + rng.randrange(4096) * 2),
        )
        await b.step(Inputs(
            rst=rng.random() < 0.015,
            query_valid=rng.random() < 0.84,
            query_pc=pc + 2 * rng.randrange(b.model.slots),
            stall=rng.random() < 0.15,
            train=train,
        ))


@cocotb.test()
async def not_taken_new_regions_do_not_evict(dut):
    b = await new_bench(dut, 18)
    assert b.model.entries == 32
    bases = [0x6000 + n * b.model.region_bytes for n in range(b.model.entries)]
    for n, pc in enumerate(bases):
        await b.step(Inputs(train=Train(valid=True, pc=pc, cfi_valid=True,
                                        cfi_type=CFI_JAL, target=0x9000+n*16)))
    fresh = bases[-1] + b.model.region_bytes
    for slot in range(b.model.slots):
        await b.step(Inputs(train=Train(valid=True, pc=fresh, br_commit_mask=1 << slot)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=fresh))
    assert not out.hit
    for pc in bases:
        _, out = await b.step(Inputs(query_valid=True, query_pc=pc))
        assert out.hit, "not-taken-only training evicted a taken region"
    # No-allocation training must not advance the global replacement pointer.
    await b.step(Inputs(train=Train(valid=True, pc=fresh, cfi_valid=True,
                                    cfi_type=CFI_JAL, target=0xA000)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=bases[0]))
    assert not out.hit
    for pc in bases[1:]:
        _, out = await b.step(Inputs(query_valid=True, query_pc=pc))
        assert out.hit
