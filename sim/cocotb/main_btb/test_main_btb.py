"""Public-port BTB tests. Each step documents pre-edge and post-edge behavior."""

import os
import random
from dataclasses import dataclass

import cocotb
from cocotb.triggers import ReadOnly, Timer

from btb_model import (
    BtbModel, CFI_BR, CFI_JAL, CFI_JALR, Inputs, RAS_POP, RAS_PUSH,
    Response, Train,
)


def value(signal) -> int:
    return int(signal.value)


@dataclass(frozen=True)
class Observed:
    valid: bool
    ready: bool
    response: Response


class Bench:
    def __init__(self, dut, seed: int) -> None:
        self.dut = dut
        self.seed = seed
        self.cycle = 0
        self.model = BtbModel(
            vaddr_bits=len(dut.s0_region_base_i),
            region_bytes=value(dut.cfg_region_bytes_o),
            sets=value(dut.cfg_sets_o),
            ways=value(dut.cfg_ways_o),
            tag_bits=value(dut.cfg_tag_bits_o),
            slots=len(dut.train_br_commit_mask_i),
        )

    def drive(self, inputs: Inputs) -> None:
        d = self.dut
        t = inputs.train
        d.clk_i.value = 0
        d.rst_i.value = int(inputs.rst)
        d.s0_valid_i.value = int(inputs.query_valid)
        d.s0_region_base_i.value = inputs.query_pc
        d.stall_i.value = int(inputs.stall)
        d.kill_i.value = int(inputs.kill)
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
            valid=bool(value(d.resp_valid_o)),
            ready=bool(value(d.train_ready_o)),
            response=Response(
                hit=bool(value(d.resp_hit_o)),
                br_mask=value(d.resp_br_mask_o),
                jal_mask=value(d.resp_jal_mask_o),
                cfi_slot=value(d.resp_cfi_slot_o),
                cfi_type=value(d.resp_cfi_type_o),
                ras_action=value(d.resp_ras_action_o),
                target=value(d.resp_target_o),
            ),
        )

    def check(self, actual: Observed, inputs: Inputs, phase: str) -> None:
        expected_valid, expected_resp = self.model.visible(inputs)
        assert int(self.dut.reserved_rvc_o.value) == 0
        assert int(self.dut.reserved_is_edge_o.value) == 0
        context = f"seed={self.seed} cycle={self.cycle} {phase} inputs={inputs}"
        assert actual.ready == (not inputs.rst), f"{context}: train_ready={actual.ready}"
        assert actual.valid == expected_valid, (
            f"{context}: resp_valid={actual.valid}, expected={expected_valid}"
        )
        if expected_valid:
            assert actual.response == expected_resp, (
                f"{context}: response={actual.response}, expected={expected_resp}"
            )

    async def step(self, inputs: Inputs) -> tuple[Observed, Observed]:
        # Cycle N, low phase: new control can suppress the old registered
        # response immediately, before a rising edge changes table/query state.
        self.drive(inputs)
        await Timer(1, unit="ns")
        await ReadOnly()
        before = self.observe()
        self.check(before, inputs, "before edge")

        # Move out of ReadOnly before writing the clock. The reference model
        # samples the old table for the query, then applies commit training.
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
    await Timer(1, unit="ns")  # Let constant configuration outputs settle.
    bench = Bench(dut, seed)
    await bench.step(Inputs(rst=True))
    await bench.step(Inputs(rst=True))
    return bench


@cocotb.test()
async def directed_contract(dut):
    b = await new_bench(dut, 0)
    a = 0x1000
    other = a + b.model.sets * b.model.region_bytes
    first_target = 0x8000_2000
    next_target = 0x8000_3000

    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert out.valid and not out.response.hit, "reset entry must miss"

    # A committed not-taken branch allocates a mask without a target owner.
    await b.step(Inputs(train=Train(valid=True, pc=a, br_commit_mask=1 << 2)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert out.valid and out.response.hit and out.response.br_mask == 1 << 2
    assert out.response.target == 0

    await b.step(Inputs(train=Train(valid=True, pc=a, cfi_valid=True,
                                    cfi_slot=2, cfi_type=CFI_BR,
                                    target=first_target, br_taken_mask=1 << 2)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert out.response.target == first_target and out.response.cfi_slot == 2

    # No taken CFI: mask grows, but the one saved target remains unchanged.
    await b.step(Inputs(train=Train(valid=True, pc=a, br_commit_mask=1 << 4,
                                    target=0xDEAD)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert out.response.br_mask == (1 << 2 | 1 << 4)
    assert out.response.target == first_target

    await b.step(Inputs(train=Train(valid=True, pc=a, cfi_valid=True,
                                    cfi_slot=6, cfi_type=CFI_JAL,
                                    ras_action=RAS_PUSH, target=next_target)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert out.response.jal_mask == 1 << 6
    assert out.response.cfi_slot == 6 and out.response.target == next_target

    # JALR can own the target, but does not create a JAL mask bit.
    await b.step(Inputs(train=Train(valid=True, pc=a, cfi_valid=True,
                                    cfi_slot=7, cfi_type=CFI_JALR,
                                    ras_action=RAS_POP, target=0x9000_0000)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert out.response.jal_mask == 1 << 6
    assert out.response.cfi_slot == 7 and out.response.ras_action == RAS_POP

    # Same-edge query and training read the OLD entry, then the new target is
    # visible only to a later query. Training is independent of query stall.
    _, out = await b.step(Inputs(query_valid=True, query_pc=a,
                                 train=Train(valid=True, pc=a, cfi_valid=True,
                                             cfi_slot=2, cfi_type=CFI_BR,
                                             target=0xA000_0000)))
    assert out.response.target == 0x9000_0000
    _, out = await b.step(Inputs(query_valid=True, query_pc=a))
    assert out.response.target == 0xA000_0000
    before, after = await b.step(Inputs(stall=True, train=Train(
        valid=True, pc=a, br_commit_mask=1 << 1)))
    assert not before.valid and not after.valid
    before, _ = await b.step(Inputs())
    assert before.valid and before.response.target == 0xA000_0000

    await b.step(Inputs(query_valid=True, query_pc=a))
    before, after = await b.step(Inputs(stall=True, kill=True))
    assert not before.valid and not after.valid
    before, _ = await b.step(Inputs())
    assert not before.valid, "kill must discard even a stalled query"

    # A no-op training packet must not allocate a new address.
    await b.step(Inputs(train=Train(valid=True, pc=other)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=other))
    assert out.valid and not out.response.hit

    # Fresh set: two fills, then per-set round-robin evicts the first way.
    await b.step(Inputs(rst=True))
    base = 0x6000
    stride = b.model.sets * b.model.region_bytes
    addresses = [base + n * stride for n in range(b.model.ways + 1)]
    for n, pc in enumerate(addresses):
        await b.step(Inputs(train=Train(valid=True, pc=pc, cfi_valid=True,
                                        cfi_slot=n, cfi_type=CFI_JAL,
                                        target=0xB000_0000 + n * 16)))
    _, out = await b.step(Inputs(query_valid=True, query_pc=addresses[0]))
    assert out.valid and not out.response.hit
    for n, pc in enumerate(addresses[1:], 1):
        _, out = await b.step(Inputs(query_valid=True, query_pc=pc))
        assert out.valid and out.response.hit
        assert out.response.target == 0xB000_0000 + n * 16
    await b.step(Inputs(rst=True))
    _, out = await b.step(Inputs(query_valid=True, query_pc=addresses[-1]))
    assert out.valid and not out.response.hit, "reset must invalidate entries"


@cocotb.test()
async def seeded_transactions(dut):
    seed = int(os.environ.get("TEST_SEED", "1"), 0)
    dut._log.info("main_btb randomized seed=%d", seed)
    b = await new_bench(dut, seed)
    rng = random.Random(seed)
    region, sets = b.model.region_bytes, b.model.sets
    addresses = [0x2000 + (n % 8) * region + (n // 8) * sets * region
                 for n in range(32)]

    for cycle in range(600):
        pc = rng.choice(addresses)
        train_pc = rng.choice(addresses)
        slot = rng.randrange(b.model.slots)
        taken = rng.random() < 0.35
        cfi_type = rng.choice((CFI_BR, CFI_JAL, CFI_JALR)) if taken else 0
        train = Train(
            valid=rng.random() < 0.55,
            pc=train_pc,
            br_commit_mask=(1 << rng.randrange(b.model.slots))
            if rng.random() < 0.75 else 0,
            br_taken_mask=(1 << slot) if taken and cfi_type == CFI_BR else 0,
            cfi_valid=taken,
            cfi_slot=slot,
            cfi_type=cfi_type,
            ras_action=rng.randrange(4),
            target=0x8000_0000 + 2 * rng.randrange(1 << 15),
        )
        await b.step(Inputs(
            rst=cycle in (200, 400),
            query_valid=rng.random() < 0.8,
            query_pc=pc,
            stall=rng.random() < 0.12,
            kill=rng.random() < 0.08,
            train=train,
        ))
