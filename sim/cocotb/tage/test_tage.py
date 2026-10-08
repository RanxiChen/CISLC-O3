"""Public-port TAGE timing and training tests with a separate cycle model."""

import os
import random
from dataclasses import dataclass

import cocotb
from cocotb.triggers import ReadOnly, Timer

from tage_model import Inputs, Response, TageModel, Train


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
        tables = value(dut.cfg_tables_o)
        index_packed = value(dut.cfg_index_bits_o)
        tag_packed = value(dut.cfg_tag_bits_o)
        self.model = TageModel(
            vaddr_bits=len(dut.s0_region_base_i),
            region_bytes=value(dut.cfg_region_bytes_o),
            slots=len(dut.resp_taken_mask_o),
            tables=tables,
            base_entries=value(dut.cfg_base_entries_o),
            index_bits=[(index_packed >> (32 * t)) & 0xFFFF_FFFF
                        for t in range(tables)],
            tag_bits=[(tag_packed >> (32 * t)) & 0xFFFF_FFFF
                      for t in range(tables)],
            ctr_bits=value(dut.cfg_ctr_bits_o),
            useful_bits=value(dut.cfg_useful_bits_o),
        )
        assert sum(n + 2 * t - 1 for n, t in zip(
            self.model.index_bits, self.model.tag_bits)) == len(dut.s0_folds_i)

    def drive(self, inputs: Inputs) -> None:
        d = self.dut
        t = inputs.train
        d.clk_i.value = 0
        d.rst_i.value = int(inputs.rst)
        d.s0_valid_i.value = int(inputs.query_valid)
        d.s0_region_base_i.value = inputs.pc
        d.s0_folds_i.value = inputs.folds
        d.stall_i.value = int(inputs.stall)
        d.kill_i.value = int(inputs.kill)
        d.train_valid_i.value = int(t.valid)
        d.train_region_base_i.value = t.pc
        d.train_folds_i.value = t.folds
        d.train_meta_i.value = t.meta
        d.train_br_commit_mask_i.value = t.commit_mask
        d.train_br_taken_mask_i.value = t.taken_mask

    def observe(self) -> Observed:
        d = self.dut
        return Observed(
            valid=bool(value(d.resp_valid_o)),
            ready=bool(value(d.train_ready_o)),
            response=Response(
                taken_mask=value(d.resp_taken_mask_o),
                provider_hit_mask=value(d.resp_provider_hit_mask_o),
                meta=value(d.resp_meta_o),
            ),
        )

    def check(self, observed: Observed, inputs: Inputs, phase: str) -> None:
        valid, ready, response = self.model.visible(inputs)
        context = f"seed={self.seed} cycle={self.cycle} {phase} inputs={inputs}"
        assert observed.valid == valid, f"{context}: valid={observed.valid}, expected={valid}"
        assert observed.ready == ready, f"{context}: ready={observed.ready}, expected={ready}"
        if valid:
            assert observed.response == response, (
                f"{context}: response={observed.response}, expected={response}"
            )

    async def step(self, inputs: Inputs) -> tuple[Observed, Observed]:
        # Before the rising edge: stall/kill suppress old S2 immediately.
        self.drive(inputs)
        await Timer(1, unit="ns")
        await ReadOnly()
        before = self.observe()
        self.check(before, inputs, "before edge")

        # Edge: S1 samples old table into S2, then commit training writes it.
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
                        train=Train(valid=True, pc=0x1000,
                                    commit_mask=1, taken_mask=1)))
    await b.step(Inputs(rst=True))
    return b


async def query(b: Bench, pc: int, folds: int = 0) -> Response:
    _, first = await b.step(Inputs(query_valid=True, pc=pc, folds=folds))
    assert not first.valid, "S0 must not bypass the S1/S2 registers"
    _, second = await b.step(Inputs())
    assert second.valid, "S2 response must appear after the second edge"
    return second.response


@cocotb.test()
async def directed_contract(dut):
    b = await new_bench(dut, 0)
    m = b.model
    a = 0x4000
    slot = 2
    initial = await query(b, a)
    assert initial.taken_mask == 0 and initial.provider_hit_mask == 0
    assert (initial.meta >> (slot * 3)) & 7 == 7, "reset selects base"

    # The original query metadata and folds, not current speculative history,
    # train one committed conditional slot. A missed direction allocates T0.
    await b.step(Inputs(train=Train(valid=True, pc=a, folds=0,
                                    meta=initial.meta, commit_mask=1 << slot,
                                    taken_mask=1 << slot)))
    after_take = await query(b, a)
    assert after_take.provider_hit_mask == (1 << m.slots) - 1
    assert after_take.taken_mask & (1 << slot)
    assert (after_take.meta >> (slot * 3)) & 7 == 0

    # Same history reinforces the provider. Different entry history changes
    # the tagged indices even though base still sees the same region PC.
    await b.step(Inputs(train=Train(valid=True, pc=a, folds=0,
                                    meta=after_take.meta, commit_mask=1 << slot,
                                    taken_mask=1 << slot)))
    strong = await query(b, a)
    assert strong.taken_mask & (1 << slot)
    offset = 0
    other_folds = 0
    for n, width in zip(m.index_bits, m.tag_bits):
        other_folds |= 1 << offset
        offset += n + 2 * width - 1
    other = await query(b, a, other_folds)
    assert other.provider_hit_mask == 0 and other.taken_mask & (1 << slot)

    # Several NT outcomes in another history reduce base, leaving the original
    # tagged provider strong taken. Its prediction then differs from base.
    for _ in range(4):
        observation = await query(b, a, other_folds)
        await b.step(Inputs(train=Train(valid=True, pc=a, folds=other_folds,
                                        meta=observation.meta,
                                        commit_mask=1 << slot)))
    original_history = await query(b, a)
    assert original_history.taken_mask & (1 << slot)
    assert ((original_history.meta >> (m.alt_offset + slot)) & 1) == 0
    assert ((original_history.meta >> (m.provider_pred_offset + slot)) & 1) == 1
    await b.step(Inputs(train=Train(valid=True, pc=a, folds=0,
                                    meta=original_history.meta,
                                    commit_mask=1 << slot,
                                    taken_mask=1 << slot)))

    # Same-edge S1 table read and training see the old row. A later query sees
    # the new value; stall keeps an existing S2 snapshot even if training runs.
    old = await query(b, a)
    await b.step(Inputs(query_valid=True, pc=a))
    _, read_old = await b.step(Inputs(train=Train(valid=True, pc=a, folds=0,
                                                 meta=old.meta,
                                                 commit_mask=1 << slot)))
    assert read_old.valid and read_old.response == old
    before, after = await b.step(Inputs(stall=True,
                                        train=Train(valid=True, pc=a, folds=0,
                                                    meta=old.meta,
                                                    commit_mask=1 << slot)))
    assert not before.valid and not after.valid
    before, _ = await b.step(Inputs())
    assert before.valid and before.response == old, "stall must retain S2 snapshot"
    await b.step(Inputs(query_valid=True, pc=a))
    before, after = await b.step(Inputs(kill=True))
    assert not before.valid and not after.valid
    before, _ = await b.step(Inputs())
    assert not before.valid, "kill must discard in-flight S1/S2"

    # A single train packet updates two independent slots of the same row.
    await b.step(Inputs(rst=True))
    fresh = await query(b, a)
    mask = (1 << 0) | (1 << 5)
    await b.step(Inputs(train=Train(valid=True, pc=a, meta=fresh.meta,
                                    commit_mask=mask, taken_mask=mask)))
    multiple = await query(b, a)
    assert multiple.taken_mask & mask == mask
    assert multiple.provider_hit_mask == (1 << m.slots) - 1
    await b.step(Inputs(rst=True))
    cleared = await query(b, a)
    assert cleared.taken_mask == 0 and cleared.provider_hit_mask == 0


@cocotb.test()
async def seeded_transactions(dut):
    seed = int(os.environ.get("TEST_SEED", "1"), 0)
    dut._log.info("TAGE randomized seed=%d", seed)
    b = await new_bench(dut, seed)
    m = b.model
    rng = random.Random(seed)
    region = 1 << m.shift
    pcs = [0x2000 + n * region for n in range(24)]
    contexts: list[tuple[int, int, int]] = []
    fold_mask = (1 << len(dut.s0_folds_i)) - 1

    for _ in range(900):
        train = Train()
        if contexts and rng.random() < 0.5:
            pc, folds, meta = rng.choice(contexts)
            commit_mask = 1 << rng.randrange(m.slots)
            if rng.random() < 0.25:
                commit_mask |= 1 << rng.randrange(m.slots)
            train = Train(valid=True, pc=pc, folds=folds, meta=meta,
                          commit_mask=commit_mask,
                          taken_mask=commit_mask & rng.getrandbits(m.slots))
        inputs = Inputs(
            rst=rng.random() < 0.012,
            query_valid=rng.random() < 0.8,
            pc=rng.choice(pcs),
            folds=rng.getrandbits(len(dut.s0_folds_i)) & fold_mask,
            stall=rng.random() < 0.11,
            kill=rng.random() < 0.04,
            train=train,
        )
        _, after = await b.step(inputs)
        if inputs.rst:
            contexts.clear()
        if after.valid and m.s2 is not None:
            contexts.append((m.s2.query.pc, m.s2.query.folds, after.response.meta))
            contexts = contexts[-32:]


@cocotb.test()
async def allocation_starts_strictly_after_each_provider(dut):
    """Exercise every variable lower bound, including the empty candidate set."""
    tables = value(dut.cfg_tables_o)
    for provider in (*range(tables), 7):
        b = await new_bench(dut, provider)
        pc = 0x8000 + provider * 0x100
        await b.step(Inputs(train=Train(valid=True, pc=pc, meta=provider,
                                       commit_mask=1, taken_mask=1)))
        prediction = await query(b, pc)
        first = provider + 1 if provider < tables else 0
        if first < tables:
            assert (prediction.meta & 7) == first
            assert prediction.provider_hit_mask == (1 << b.model.slots) - 1
        else:
            assert (prediction.meta & 7) == 7
            assert prediction.provider_hit_mask == 0

@cocotb.test()
async def consecutive_rows_match_frozen_legacy_bitwise(dut):
    from legacy_tage_reference import TageModel as Legacy, Train as OldTrain
    b=await new_bench(dut,29);m=b.model
    ref=Legacy(vaddr_bits=m.vaddr_bits,region_bytes=1<<m.shift,slots=m.slots,
        tables=m.tables,base_entries=m.base_entries,index_bits=m.index_bits,tag_bits=m.tag_bits,
        ctr_bits=m.ctr_bits,useful_bits=m.useful_bits)
    rng=random.Random(29);previous=None;pc=0x4000
    for n in range(256):
        mask=rng.randrange(1,256)
        pred=ref.predict(ref.snapshot(ref.query(pc,0)))
        t=Train(True,pc,0,pred.meta,mask,rng.getrandbits(8)&mask)
        await b.step(Inputs(query_valid=True,pc=pc,train=t))
        if previous is not None:ref.train(previous)
        previous=OldTrain(t.valid,t.pc,t.folds,t.meta,t.commit_mask,t.taken_mask)
        q=ref.query(pc,0)
        packed=sum(v<<(s*m.ctr_bits) for s,v in enumerate(ref.base[q.base_idx]))
        assert int(dut.mon_base_o.value)==packed
        rows=int(dut.mon_rows_o.value);width=len(dut.mon_rows_o)//m.tables
        for j in range(m.tables):
            r=ref.tagged[j][q.idx[j]]
            if r.valid:
                ctr=sum(v<<(s*m.ctr_bits) for s,v in enumerate(r.ctr))
                useful=sum(v<<(s*m.useful_bits) for s,v in enumerate(r.useful))
                expected=(1<<(width-1)) | (r.tag<<(m.slots*(m.ctr_bits+m.useful_bits))) | (ctr<<(m.slots*m.useful_bits)) | useful
                assert (rows>>(j*width))&((1<<width)-1)==expected,(n,j)
    await b.step(Inputs());ref.train(previous)
    await query(b,pc)
    assert b.model.base==ref.base and all(vars(a)==vars(c) for ar,cr in zip(b.model.tagged,ref.tagged) for a,c in zip(ar,cr))
