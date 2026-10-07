"""L7a F1 predecode correction (spec 4.2-4.4, 9.1 ifu_f1 row)."""
import os
import random

import cocotb
from cocotb.triggers import ReadOnly, Timer
from ifu_f1_model import (CFI_BR, CFI_JAL, CFI_JALR, CFI_NONE, NOP, RAS_NONE, RAS_POP,
                          RAS_POP_PUSH, RAS_PUSH, Inputs, Item, Pred, addi, block, branch,
                          decode, evaluate, jal, jalr)

BASE = 0x8000_1000      # 16B-aligned region; slot s is at BASE + 2*s
RA_TOP = 0x8000_4440    # RAS checkpoint top address used by return cases
FAR = 0x9000_0000       # a predicted next_pc that is never the right answer


def val(signal):
    return int(signal.value)


def field(signal, lane, bits):
    return (val(signal) >> (lane * bits)) & ((1 << bits) - 1)


def pack(values, bits):
    return sum((v & ((1 << bits) - 1)) << (n * bits) for n, v in enumerate(values))


class Bench:
    def __init__(self, dut, seed=0):
        self.dut = dut
        self.seed = seed
        self.cycle = 0
        self.width = val(dut.cfg_f1_width_o)
        self.pending = None    # request the model expects on predecode_o this cycle

    def drive(self, i):
        d = self.dut
        slots = len(d.in_valid_i)
        pc_bits = len(d.brief_next_pc_i)
        word_bits = len(d.in_inst_flat_i) // slots
        id_bits = len(d.in_id_flat_i) // slots
        cause_bits = len(d.in_exc_cause_flat_i) // slots
        tval_bits = len(d.in_exc_tval_flat_i) // slots
        by_slot = {it.slot: it for it in i.items}
        get = lambda attr: [getattr(by_slot[s], attr) if s in by_slot else 0 for s in range(slots)]
        d.beat_valid_i.value=int(bool(i.items) or i.beat)
        d.last_i.value=int(i.last);d.edge_pend_i.value=int(i.edge_pend)
        d.in_len_flat_i.value=pack(get('inst_len'),3)
        d.in_edge_i.value=sum(1<<s for s,it in by_slot.items() if it.edge)
        d.rst_i.value = int(i.rst)
        d.in_valid_i.value = sum(1 << s for s in by_slot)
        d.in_pc_flat_i.value = pack(get("pc"), pc_bits)
        d.in_inst_flat_i.value = pack(get("word"), word_bits)
        d.in_id_flat_i.value = pack(get("ftq_id"), id_bits)
        d.in_exc_valid_i.value = sum(1 << s for s, it in by_slot.items() if it.exc)
        d.in_exc_cause_flat_i.value = pack(get("cause"), cause_bits)
        d.in_exc_tval_flat_i.value = pack(get("tval"), tval_bits)
        p = i.pred
        d.brief_base_i.value=p.base;d.brief_id_i.value=p.ftq_id
        d.brief_rvc_i.value=int(p.rvc);d.brief_edge_i.value=int(p.edge)
        d.brief_cfi_valid_i.value = int(p.cfi_valid)
        d.brief_cfi_slot_i.value = p.cfi_slot
        d.brief_cfi_type_i.value = p.cfi_type
        d.brief_ras_action_i.value = p.ras_action
        d.brief_cfi_target_i.value = p.cfi_target
        d.brief_next_pc_i.value = p.next_pc
        d.brief_raw_taken_i.value = int(p.raw_taken)
        d.brief_ras_count_i.value = p.ras_count
        d.brief_ras_top_i.value = p.ras_top
        d.out_ready_i.value = int(i.ready)
        d.kill_valid_i.value = int(i.kill)

    def check_request(self, ctx):
        d, exp = self.dut, self.pending
        assert val(d.predecode_valid_o) == int(exp is not None), f"{ctx} predecode valid"
        if exp is None:
            return
        got = {"src": val(d.pd_src_o), "ftq_id": val(d.pd_ftq_id_o), "slot": val(d.pd_slot_o),
               "kill_self": val(d.pd_kill_self_o), "target": val(d.pd_target_o),
               "hist_inject": val(d.pd_hist_inject_o), "hist_branch": val(d.pd_hist_branch_o),
               "hist_target": val(d.pd_hist_target_o), "ras_fix": val(d.pd_ras_fix_o),
               "push_addr": val(d.pd_push_addr_o)}
        assert got == exp, f"{ctx} predecode req\n got={got}\n exp={exp}"

    def check_entries(self, out, ready, ctx):
        d = self.dut
        mask = (1 << len(out)) - 1
        assert val(d.in_ready_o) == ready, f"{ctx} in_ready"
        assert val(d.out_valid_o) == mask, f"{ctx} out_valid {val(d.out_valid_o):#x} != {mask:#x}"
        assert val(d.entry_valid_o) & mask == mask, ctx
        pc_bits = len(d.brief_next_pc_i)
        slot_bits = len(d.brief_cfi_slot_i)
        word_bits = len(d.out_inst_flat_o) // self.width
        id_bits = len(d.out_id_flat_o) // self.width
        cause_bits = len(d.out_exc_cause_flat_o) // self.width
        tval_bits = len(d.out_exc_tval_flat_o) // self.width
        for lane, e in enumerate(out):
            got = {"pc": field(d.out_pc_flat_o, lane, pc_bits),
                   "word": field(d.out_inst_flat_o, lane, word_bits),
                   "ftq_id": field(d.out_id_flat_o, lane, id_bits),
                   "slot": field(d.out_slot_flat_o, lane, slot_bits),
                   "exc": bool(val(d.out_exc_valid_o) >> lane & 1),
                   "cause": field(d.out_exc_cause_flat_o, lane, cause_bits),
                   "tval": field(d.out_exc_tval_flat_o, lane, tval_bits),
                   "taken": bool(val(d.pred_taken_o) >> lane & 1),
                   "next_pc": field(d.out_next_flat_o, lane, pc_bits),
                   "last": bool(val(d.ftq_last_o) >> lane & 1)}
            assert field(d.out_raw_flat_o, lane, word_bits) == e["word"], f"{ctx} lane{lane} raw"
            if not e["exc"]:
                got["cause"], got["tval"] = e["cause"], e["tval"]
            assert got == e, f"{ctx} lane{lane}\n got={got}\n exp={e}"

    async def step(self, i, note=""):
        d = self.dut
        d.clk_i.value = 0
        self.drive(i)
        await Timer(1, unit="ns")
        await ReadOnly()
        ctx = f"seed={self.seed} cycle={self.cycle} {note}"
        ready, out, req = evaluate(i, self.width)
        self.check_request(ctx)
        self.check_entries(out, ready, ctx)
        fire = ready and (bool(i.items) or i.beat)
        self.pending = req if fire else None
        await Timer(1, unit="ns")
        d.clk_i.value = 1
        await Timer(1, unit="ns")
        d.clk_i.value = 0
        self.cycle += 1
        return out, req

    async def reset(self):
        # A new case shares RTL state with the previous case. pd_req_q resets
        # synchronously: do not assume zero before the first reset edge.
        self.dut.clk_i.value = 0
        self.drive(Inputs(rst=True))
        await Timer(1, unit="ns")
        self.dut.clk_i.value = 1
        await Timer(1, unit="ns")
        self.dut.clk_i.value = 0
        self.pending = None
        await self.step(Inputs(rst=True), "reset")

    async def case(self, note, i, exp_lanes=None, exp_taken=None, exp_next=None, exp_req=None):
        """Present one block, check model output, then an idle cycle that must show the request."""
        out, req = await self.step(i, note)
        # Spec-level sanity on top of the model (guards against a wrong model).
        if exp_lanes is not None:
            assert len(out) == exp_lanes, f"{note}: model lanes {len(out)} != {exp_lanes}"
        if exp_taken is not None:
            assert out[-1]["taken"] == exp_taken, f"{note}: model pred_taken"
        if exp_next is not None:
            assert out[-1]["next_pc"] == exp_next, f"{note}: model next_pc"
        if exp_req is not None:
            assert req is not None and all(req[k] == v for k, v in exp_req.items()), \
                f"{note}: model req {req}"
        await self.step(Inputs(), note + " +1")   # request appears here, exactly once
        await self.step(Inputs(), note + " +2")   # and is gone here


def pc(slot):
    return BASE + 2 * slot


def tgt(slot, imm):
    return pc(slot) + imm


@cocotb.test()
async def unmodified_blocks(dut):
    """4.4: no exit -> all pc+4; correct BR exit -> taken with pred.next_pc; no request."""
    b = Bench(dut)
    await b.reset()
    await b.case("sequential", Inputs(items=block(BASE, [NOP] * 4)), exp_lanes=4)
    words = [NOP, NOP, branch(1, 2, 0x40), NOP]
    p = Pred(cfi_valid=True, cfi_slot=4, cfi_type=CFI_BR, cfi_target=tgt(4, 0x40),
             next_pc=tgt(4, 0x40), raw_taken=True)
    out, req = await b.step(Inputs(items=block(BASE, words), pred=p), "BR exit ok")
    assert req is None and len(out) == 3 and out[-1]["taken"]
    await b.step(Inputs(), "idle")
    # Backpressure: nothing handshakes, nothing is latched.
    await b.step(Inputs(items=block(BASE, words), pred=p, ready=False), "stall")


@cocotb.test()
async def rule_a_early_jal(dut):
    b = Bench(dut)
    await b.reset()
    words = [NOP, jal(1, 0x100), NOP, NOP]
    await b.case("a: early JAL, no exit, truncates after slot 2",
                 Inputs(items=block(BASE, words, ftq_id=3)), exp_lanes=2, exp_taken=True,
                 exp_next=tgt(2, 0x100),
                 exp_req={"slot": 2, "ras_fix": RAS_PUSH, "push_addr": pc(2) + 4, "hist_inject": 0})
    # a also fires before a predicted exit later in the block; rd=x0 -> RAS_NONE.
    p = Pred(cfi_valid=True, cfi_slot=6, cfi_type=CFI_BR, cfi_target=FAR, next_pc=FAR)
    await b.case("a: JAL x0 before predicted BR exit",
                 Inputs(items=block(BASE, [NOP, jal(0, -0x20), NOP, branch(1, 2, 8)]), pred=p),
                 exp_lanes=2, exp_next=tgt(2, -0x20), exp_req={"ras_fix": RAS_NONE})


@cocotb.test()
async def rule_b_early_return(dut):
    b = Bench(dut)
    await b.reset()
    p = Pred(ras_count=2, ras_top=RA_TOP)
    await b.case("b: early ret with RAS count!=0",
                 Inputs(items=block(BASE, [jalr(0, 1), NOP, NOP, NOP]), pred=p),
                 exp_lanes=1, exp_taken=True, exp_next=RA_TOP, exp_req={"ras_fix": RAS_POP})
    await b.case("b: coroutine jalr x1,x5 -> POP_PUSH",
                 Inputs(items=block(BASE, [NOP, jalr(1, 5), NOP, NOP]), pred=p),
                 exp_lanes=2, exp_next=RA_TOP, exp_req={"ras_fix": RAS_POP_PUSH})


@cocotb.test()
async def rule_c_false_cfi(dut):
    b = Bench(dut)
    await b.reset()
    p = Pred(cfi_valid=True, cfi_slot=4, cfi_type=CFI_BR, cfi_target=FAR, next_pc=FAR,
             raw_taken=True)
    await b.case("c: exit on non-CFI", Inputs(items=block(BASE, [NOP, NOP, NOP, NOP]), pred=p),
                 exp_lanes=3, exp_taken=False, exp_next=pc(4) + 4,
                 exp_req={"slot": 4, "ras_fix": RAS_NONE, "hist_inject": 0})
    p = Pred(cfi_valid=True, cfi_slot=3, cfi_type=CFI_BR, cfi_target=FAR, next_pc=FAR)
    await b.case("c: exit slot 3 is the second half of slot-2 BR",
                 Inputs(items=block(BASE, [NOP, branch(1, 2, 0x10), NOP, NOP]), pred=p),
                 exp_lanes=2, exp_taken=False, exp_next=pc(2) + 4, exp_req={"slot": 2})


@cocotb.test()
async def rule_a_beats_c(dut):
    """U19 example: exit slot 1, slot 0 JAL -> a; slot 0 BR -> c."""
    b = Bench(dut)
    await b.reset()
    p = Pred(cfi_valid=True, cfi_slot=1, cfi_type=CFI_JAL, cfi_target=FAR, next_pc=FAR)
    await b.case("a over c", Inputs(items=block(BASE, [jal(0, 0x80), NOP, NOP, NOP]), pred=p),
                 exp_lanes=1, exp_taken=True, exp_next=tgt(0, 0x80))
    await b.case("c when slot 0 is BR", Inputs(items=block(BASE, [branch(3, 4, 0x80), NOP]), pred=p),
                 exp_lanes=1, exp_taken=False, exp_next=pc(0) + 4)


@cocotb.test()
async def rule_d_type_mismatch(dut):
    b = Bench(dut)
    await b.reset()
    p = Pred(cfi_valid=True, cfi_slot=2, cfi_type=CFI_BR, cfi_target=FAR, next_pc=FAR)
    await b.case("d: predicted BR, actual JAL -> A(i)",
                 Inputs(items=block(BASE, [NOP, jal(1, 0x200), NOP]), pred=p),
                 exp_lanes=2, exp_taken=True, exp_next=tgt(2, 0x200), exp_req={"ras_fix": RAS_PUSH})
    p = Pred(cfi_valid=True, cfi_slot=2, cfi_type=CFI_JAL, ras_action=RAS_PUSH,
             cfi_target=FAR, next_pc=FAR)
    await b.case("d: predicted JAL, actual BR -> sequential",
                 Inputs(items=block(BASE, [NOP, branch(1, 2, 0x40), NOP]), pred=p),
                 exp_lanes=2, exp_taken=False, exp_next=pc(2) + 4, exp_req={"ras_fix": RAS_NONE})
    p = Pred(cfi_valid=True, cfi_slot=0, cfi_type=CFI_BR, cfi_target=FAR, next_pc=FAR,
             ras_count=1, ras_top=RA_TOP)
    await b.case("d: predicted BR, actual ret with stack -> RAS top",
                 Inputs(items=block(BASE, [jalr(0, 1), NOP]), pred=p),
                 exp_lanes=1, exp_taken=True, exp_next=RA_TOP, exp_req={"ras_fix": RAS_POP})
    p = Pred(cfi_valid=True, cfi_slot=0, cfi_type=CFI_BR, next_pc=FAR,
             ras_count=0, ras_top=RA_TOP)
    await b.case("d: empty-stack return has no A(i)",
                 Inputs(items=block(BASE, [jalr(0, 1), NOP]), pred=p),
                 exp_lanes=1, exp_taken=False, exp_next=BASE + 4,
                 exp_req={"ras_fix": RAS_NONE})


@cocotb.test()
async def rule_e_direct_target(dut):
    b = Bench(dut)
    await b.reset()
    p = Pred(cfi_valid=True, cfi_slot=2, cfi_type=CFI_BR, cfi_target=FAR, next_pc=FAR,
             raw_taken=True)
    await b.case("e: BR wrong target, hist_inject",
                 Inputs(items=block(BASE, [NOP, branch(1, 2, -0x10), NOP]), pred=p),
                 exp_lanes=2, exp_taken=True, exp_next=tgt(2, -0x10),
                 exp_req={"hist_inject": 1, "hist_target": tgt(2, -0x10), "ras_fix": RAS_NONE})
    await b.case("e: BR target == pc+4 still taken (U8)",
                 Inputs(items=block(BASE, [NOP, branch(1, 2, 4), NOP]), pred=p),
                 exp_lanes=2, exp_taken=True, exp_next=pc(2) + 4, exp_req={"hist_inject": 1})
    p = Pred(cfi_valid=True, cfi_slot=2, cfi_type=CFI_JAL, cfi_target=FAR, next_pc=FAR)
    await b.case("e: JAL wrong target",
                 Inputs(items=block(BASE, [NOP, jal(0, 0x30)]), pred=p),
                 exp_lanes=2, exp_taken=True, exp_next=tgt(2, 0x30), exp_req={"hist_inject": 0})
    p = Pred(cfi_valid=True, cfi_slot=2, cfi_type=CFI_JAL, ras_action=RAS_NONE,
             cfi_target=tgt(2, 0x30), next_pc=tgt(2, 0x30))
    await b.case("e: JAL same target, ras_action differs (U9)",
                 Inputs(items=block(BASE, [NOP, jal(1, 0x30)]), pred=p),
                 exp_lanes=2, exp_taken=True, exp_next=tgt(2, 0x30), exp_req={"ras_fix": RAS_PUSH})


@cocotb.test()
async def rule_f_jalr_ras(dut):
    b = Bench(dut)
    await b.reset()
    p = Pred(cfi_valid=True, cfi_slot=2, cfi_type=CFI_JALR, ras_action=RAS_NONE,
             next_pc=FAR, ras_count=3, ras_top=RA_TOP)
    await b.case("f: JALR predicted NONE, actual ret -> top",
                 Inputs(items=block(BASE, [NOP, jalr(0, 1)]), pred=p),
                 exp_lanes=2, exp_taken=True, exp_next=RA_TOP, exp_req={"ras_fix": RAS_POP})
    p = Pred(cfi_valid=True, cfi_slot=2, cfi_type=CFI_JALR, ras_action=RAS_NONE,
             next_pc=FAR, ras_count=0, ras_top=RA_TOP)
    await b.case("f: empty stack keeps pred.next_pc (U19)",
                 Inputs(items=block(BASE, [NOP, jalr(0, 1)]), pred=p),
                 exp_lanes=2, exp_taken=True, exp_next=FAR, exp_req={"ras_fix": RAS_POP})
    p = Pred(cfi_valid=True, cfi_slot=2, cfi_type=CFI_JALR, ras_action=RAS_NONE, next_pc=FAR)
    await b.case("f: call jalr x1,0(x6) predicted NONE -> PUSH, target kept",
                 Inputs(items=block(BASE, [NOP, jalr(1, 6)]), pred=p),
                 exp_lanes=2, exp_taken=True, exp_next=FAR, exp_req={"ras_fix": RAS_PUSH})


@cocotb.test()
async def no_correction_cases(dut):
    """Spec 4.2 '不修正': BR direction, plain JALR target, empty-stack return target."""
    b = Bench(dut)
    await b.reset()
    out, req = await b.step(Inputs(items=block(BASE, [branch(1, 2, 0x40), NOP, NOP, NOP])),
                            "unpredicted BR")
    assert req is None and len(out) == 4
    p = Pred(cfi_valid=True, cfi_slot=2, cfi_type=CFI_JALR, ras_action=RAS_NONE, next_pc=FAR)
    out, req = await b.step(Inputs(items=block(BASE, [NOP, jalr(0, 6, 8), NOP]), pred=p),
                            "plain JALR exit, any target")
    assert req is None and out[-1]["next_pc"] == FAR and out[-1]["taken"]
    out, req = await b.step(Inputs(items=block(BASE, [jalr(0, 6), NOP, NOP, NOP])),
                            "unpredicted plain JALR")
    assert req is None and len(out) == 4
    out, req = await b.step(Inputs(items=block(BASE, [NOP, jalr(0, 1), NOP, NOP]),
                                   pred=Pred(ras_count=0, ras_top=RA_TOP)),
                            "empty-stack ret, no exit")
    assert req is None and len(out) == 4
    await b.step(Inputs(), "idle")


@cocotb.test()
async def exceptions(dut):
    """U10/U20: stop at first exception item; deliver it unchanged with ftq_last."""
    b = Bench(dut)
    await b.reset()
    await b.case("first item exc (word decodes as JAL)",
                 Inputs(items=block(BASE, [jal(1, 0x40), jal(1, 0x80), NOP, NOP],
                                    exc={0: (1, pc(0))})),
                 exp_lanes=1, exp_taken=False, exp_next=pc(0) + 4)
    p = Pred(cfi_valid=True, cfi_slot=6, cfi_type=CFI_BR, cfi_target=FAR, next_pc=FAR)
    await b.case("middle item exc before exit",
                 Inputs(items=block(BASE, [NOP, NOP, branch(1, 1, 8), NOP],
                                    exc={1: (12, pc(2))}), pred=p),
                 exp_lanes=2, exp_taken=False)
    await b.case("fix before exc: exc item not delivered",
                 Inputs(items=block(BASE, [jal(0, 0x40), NOP], exc={1: (1, pc(2))})),
                 exp_lanes=1, exp_taken=True, exp_req={"slot": 0})


@cocotb.test()
async def request_timing(dut):
    """4.3: request one cycle after the handshake, exactly once; stall/kill latch nothing."""
    b = Bench(dut)
    await b.reset()
    fixing = Inputs(items=block(BASE, [jal(0, 0x40), NOP]))
    await b.step(Inputs(items=fixing.items, ready=False), "stalled fixing block")
    await b.step(Inputs(items=fixing.items, kill=True), "killed fixing block")
    await b.step(Inputs(items=fixing.items), "handshake")
    # The next block is stalled; the request must still show once and then clear.
    await b.step(Inputs(items=fixing.items, ready=False), "+1 next block stalled")
    await b.step(Inputs(items=fixing.items, ready=False), "+2 still stalled")
    # Back-to-back fixing blocks: each produces its own single request.
    await b.step(Inputs(items=block(BASE, [jal(0, 0x40)], ftq_id=1)), "blk1")
    await b.step(Inputs(items=block(BASE, [NOP, jal(0, 0x80)], ftq_id=2)), "blk2")
    await b.step(Inputs(), "+1")
    await b.step(Inputs(), "+2")


def random_word(rng):
    link = lambda: rng.choice([0, 1, 5, 6, 1, 5])
    return rng.choice([
        lambda: NOP,
        lambda: addi(rng.randrange(32), rng.randrange(32), rng.randrange(-2048, 2048)),
        lambda: branch(rng.randrange(32), rng.randrange(32), 2 * rng.randrange(-64, 64),
                       rng.choice([0, 1, 4, 5, 6, 7])),
        lambda: jal(link(), 2 * rng.randrange(-512, 512)),
        lambda: jalr(link(), link(), rng.randrange(-16, 16)),
    ])()


@cocotb.test()
async def seeded_transactions(dut):
    seed = int(os.environ.get("TEST_SEED", "1"), 0)
    rng = random.Random(seed)
    b = Bench(dut, seed)
    await b.reset()
    for cycle in range(400):
        start = 2 * rng.randrange(4)
        n = rng.randrange(1, 5 - start // 2)
        base = 0x8000_0000 + 16 * rng.randrange(1 << 12)
        words = [random_word(rng) for _ in range(n)]
        exc = {}
        if rng.random() < 0.1:
            exc[rng.randrange(n)] = (rng.choice([1, 12]), base + rng.randrange(8) * 2)
        items = block(base, words, ftq_id=cycle & 7, start_slot=start, exc=exc)
        pred = Pred()
        if rng.random() < 0.6:
            slot = rng.randrange(start, 8)
            # Bias the predicted fields toward the real decode so e/f and no-fix paths are hit.
            real = next((decode(it.word, it.pc) for it in items if it.slot == slot), None)
            t, ras, direct = real if real and rng.random() < 0.6 else (
                rng.randrange(4), rng.randrange(4), None)
            target = direct if direct is not None and rng.random() < 0.7 else FAR
            pred = Pred(cfi_valid=True, cfi_slot=slot, cfi_type=t, ras_action=ras,
                        cfi_target=target, next_pc=target, raw_taken=True)
        pred = Pred(**{**pred.__dict__, "ras_count": rng.choice([0, 1, 4]),
                       "ras_top": 0x8000_7000 + 4 * rng.randrange(64)})
        await b.step(Inputs(items=items, pred=pred, ready=rng.random() < 0.8,
                            kill=rng.random() < 0.05), f"rand n={n} start={start}")


@cocotb.test()
async def priority_and_first_correction(dut):
    b = Bench(dut)
    await b.reset()
    p = Pred(cfi_valid=True, cfi_slot=1, cfi_type=CFI_BR, next_pc=FAR,
             ras_count=1, ras_top=RA_TOP)
    await b.case("b beats c at the second halfword",
                 Inputs(items=block(BASE, [jalr(5, 1), jal(1, 64)]), pred=p),
                 exp_lanes=1, exp_taken=True, exp_next=RA_TOP,
                 exp_req={"slot": 0, "ras_fix": RAS_POP_PUSH})
    await b.case("first of two JALs wins",
                 Inputs(items=block(BASE, [NOP, jal(5, 32), jal(1, 64), NOP])),
                 exp_lanes=2, exp_next=pc(2) + 32, exp_req={"slot": 2})


@cocotb.test()
async def link_register_matrix(dut):
    b = Bench(dut)
    await b.reset()
    # Independent ISA hint table: rows rd={x0,x1,x5,x6}; columns rs1 likewise.
    regs = (0, 1, 5, 6)
    hints = ((0, 2, 2, 0), (1, 1, 3, 1), (1, 3, 1, 1), (0, 2, 2, 0))
    for row, rd in enumerate(regs):
        for col, rs1 in enumerate(regs):
            for count in (0, 1):
                action = hints[row][col]
                p = Pred(cfi_valid=True, cfi_slot=0, cfi_type=CFI_JALR,
                         ras_action=(action + 1) % 4, next_pc=FAR,
                         ras_count=count, ras_top=RA_TOP)
                target = RA_TOP if count and action in (RAS_POP, RAS_POP_PUSH) else FAR
                await b.case(f"rd={rd} rs1={rs1} count={count}",
                             Inputs(items=block(BASE, [jalr(rd, rs1)]), pred=p),
                             exp_lanes=1, exp_taken=True, exp_next=target,
                             exp_req={"ras_fix": action, "push_addr": BASE + 4})
    p = Pred(cfi_valid=True, cfi_slot=0, cfi_type=CFI_JALR,
             ras_action=RAS_NONE, next_pc=BASE + 4, ras_count=0)
    await b.case("f keeps taken even when retained target is pc+4",
                 Inputs(items=block(BASE, [jalr(0, 1)]), pred=p),
                 exp_taken=True, exp_next=BASE + 4, exp_req={"ras_fix": RAS_POP})


@cocotb.test()
async def immediate_boundaries_and_reserved_encodings(dut):
    b = Bench(dut)
    await b.reset()
    for imm in (-1048576, -4096, -2048, 0, 4, 2048, 4096, 1048572):
        await b.case(f"JAL imm={imm}", Inputs(items=block(BASE, [jal(0, imm)])),
                     exp_next=BASE + imm, exp_taken=True)
    p = Pred(cfi_valid=True, cfi_slot=0, cfi_type=CFI_BR,
             cfi_target=FAR, next_pc=FAR)
    for imm in (-4096, -2048, 0, 4, 2048, 4092):
        for funct3 in (0, 1, 4, 5, 6, 7):
            await b.case(f"BR funct3={funct3} imm={imm}",
                         Inputs(items=block(BASE, [branch(2, 3, imm, funct3)]), pred=p),
                         exp_next=BASE + imm, exp_taken=True, exp_req={"hist_inject": 1})
    for word in (branch(1, 2, 8, 2), branch(1, 2, 8, 3), jalr(1, 5) | (1 << 12)):
        await b.case("reserved funct3 is not CFI", Inputs(items=block(BASE, [word]), pred=p),
                     exp_taken=False, exp_next=BASE + 4, exp_req={"ras_fix": RAS_NONE})


@cocotb.test()
async def exception_at_exit_and_held_transaction(dut):
    b = Bench(dut)
    await b.reset()
    p = Pred(cfi_valid=True, cfi_slot=2, cfi_type=CFI_JAL,
             cfi_target=FAR, next_pc=FAR)
    out, req = await b.step(Inputs(items=block(BASE, [NOP, jal(1, 64), jal(5, 128)],
                                              exc={1: (1, pc(2))}), pred=p))
    assert req is None and len(out) == 2
    assert out[-1]["exc"] and out[-1]["last"] and out[-1]["taken"]
    assert out[-1]["next_pc"] == FAR
    fixing = block(BASE, [NOP, jal(5, 64), NOP], ftq_id=5)
    for _ in range(6):
        await b.step(Inputs(items=fixing, ready=False), "same block held")
    await b.step(Inputs(items=fixing), "release")
    # kill must not combinationally suppress the already registered request.
    await b.step(Inputs(items=block(BASE + 16, [jal(1, 32)], ftq_id=6), kill=True),
                 "pending request plus kill of younger block")
    await b.step(Inputs(), "pending clears, killed younger creates no request")


@cocotb.test()
async def pending_request_resets_at_clock_edge(dut):
    b = Bench(dut)
    await b.reset()
    await b.step(Inputs(items=block(BASE, [jal(1, 64)])), "latch request")
    await b.step(Inputs(rst=True), "request still registered before reset edge")
    await b.step(Inputs(rst=True), "request cleared after reset edge")
    await b.step(Inputs(), "reset release has no stale request")

@cocotb.test()
async def l7b_length_edge_and_empty_beats(d):
    b=Bench(d);await b.reset()
    # A compressed call expands to JALR but must push pc+2; same action with
    # a predicted four-byte length is still a RAS mismatch.
    it=Item(0,BASE,jalr(1,7),ftq_id=3,inst_len=2)
    await b.case('compressed call length mismatch',Inputs(items=(it,),
        pred=Pred(True,0,CFI_JALR,RAS_PUSH,next_pc=FAR,rvc=False)),
        exp_lanes=1,exp_req={'target':FAR,'push_addr':BASE+2,'ras_fix':RAS_PUSH})
    # Edge belongs to the second region at slot 0, PC two bytes before base.
    edge=Item(0,BASE-2,branch(2,3,20),ftq_id=4,edge=True)
    await b.case('edge exit matches',Inputs(items=(edge,),
        pred=Pred(True,0,CFI_BR,cfi_target=BASE+18,next_pc=BASE+18,edge=True)),exp_lanes=1)
    for note,item,pred in [
        ('predicted edge absent',Item(0,BASE,NOP,4),Pred(True,0,CFI_BR,edge=True,next_pc=FAR)),
        ('slot zero is edge tail',edge,Pred(True,0,CFI_BR,cfi_target=BASE+18,next_pc=FAR))]:
        await b.case(note,Inputs(items=(item,),pred=pred),exp_lanes=1,exp_taken=False,
            exp_next=item.pc+4,exp_req={'target':item.pc+4})
    # c-prime must register even though there are no delivery lanes.
    await b.case('empty c-prime',Inputs(beat=True,edge_pend=True,
        pred=Pred(True,7,CFI_JAL,next_pc=FAR,base=BASE,ftq_id=5)),
        exp_lanes=0,exp_req={'slot':7,'ftq_id':5,'target':BASE+16})
    for last in (False,True):
        out,_=await b.step(Inputs(items=block(BASE,(NOP,)*4,7),last=last),'two-beat last marker')
        assert out[-1]['last']==last
    # RVC sequential successor and direct BR target retain two-byte length.
    rv=Item(2,BASE+4,NOP,inst_len=2)
    await b.case('RVC false CFI',Inputs(items=(rv,),pred=Pred(True,2,CFI_BR,next_pc=FAR)),
        exp_lanes=1,exp_taken=False,exp_next=BASE+6,exp_req={'target':BASE+6})
