"""Check RAS outputs before and after each edge, including recovery priority."""

import os
import random

import cocotb
from cocotb.triggers import Timer

from ras_model import Checkpoint, Inputs, NONE, POP, POP_PUSH, PUSH, RasModel


def val(signal) -> int:
    return int(signal.value)


class Bench:
    def __init__(self, dut):
        self.d = dut
        self.model = RasModel(val(dut.depth_o))
        self.cycle = 0

    def drive(self, inp: Inputs):
        d = self.d
        d.clk_i.value = 0
        d.rst_i.value = inp.reset
        d.op_valid_i.value = inp.op_valid
        d.op_action_i.value = inp.op
        d.op_push_addr_i.value = inp.op_addr
        d.recover_valid_i.value = inp.recover
        d.recover_id_i.value = inp.recover_id
        d.recover_top_idx_i.value = inp.ckpt.idx
        d.recover_count_i.value = inp.ckpt.count
        d.recover_top_addr_i.value = inp.ckpt.addr
        d.recover_fix_i.value = inp.fix
        d.recover_push_addr_i.value = inp.fix_addr

    def check(self, inp: Inputs, phase: str):
        d = self.d
        ck = self.model.checkpoint()
        got = (val(d.top_valid_o), val(d.top_o), val(d.ckpt_top_idx_o),
               val(d.ckpt_count_o), val(d.ckpt_top_addr_o),
               val(d.recover_done_o), val(d.recover_done_id_o),
               val(d.events_o))
        expected = (int(bool(ck.count)), ck.addr, ck.idx, ck.count, ck.addr,
                    int(inp.recover and not inp.reset),
                    inp.recover_id if inp.recover and not inp.reset else 0,
                    self.model.events(inp))
        assert got == expected, (
            f"cycle={self.cycle} {phase} depth={self.model.depth} "
            f"input={inp} got={got} expected={expected}"
        )

    async def step(self, inp: Inputs):
        # The combinational checkpoint and top describe the OLD stack.
        self.drive(inp)
        await Timer(1, unit="ns")
        self.check(inp, "before edge")
        self.d.clk_i.value = 1
        self.model.advance(inp)
        await Timer(1, unit="ns")
        # After the edge, the same inputs remain asserted, but top/ckpt show
        # the NEW stack. A second edge would perform a second operation.
        self.check(inp, "after edge")
        self.d.clk_i.value = 0
        await Timer(1, unit="ns")
        self.cycle += 1


async def fresh(dut) -> Bench:
    bench = Bench(dut)
    # At time zero there is no defined flop state to compare. Establish the
    # first reset edge, then begin strict before/after checks from cycle one.
    inp = Inputs(reset=True)
    bench.drive(inp)
    await Timer(1, unit="ns")
    dut.clk_i.value = 1
    bench.model.advance(inp)
    await Timer(1, unit="ns")
    bench.check(inp, "after initial reset edge")
    dut.clk_i.value = 0
    await Timer(1, unit="ns")
    bench.cycle = 1
    return bench


@cocotb.test()
async def directed_edges_and_recovery(dut):
    b = await fresh(dut)
    depth = b.model.depth
    assert b.model.checkpoint() == Checkpoint(depth - 1, 0, 0)

    await b.step(Inputs(op=PUSH, op_addr=0x111))  # invalid: no update
    await b.step(Inputs(op_valid=True, op=POP))   # empty pop: no update
    assert b.model.count == 0
    await b.step(Inputs(op_valid=True, op=POP_PUSH, op_addr=0x222))
    assert b.model.checkpoint().addr == 0x222
    await b.step(Inputs(op_valid=True, op=POP_PUSH, op_addr=0x333))
    assert b.model.checkpoint().addr == 0x333
    await b.step(Inputs(op_valid=True, op=POP))
    assert b.model.count == 0

    # Fill, wrap, overwrite oldest at full count, then drain to empty.
    for n in range(depth + 2):
        await b.step(Inputs(op_valid=True, op=PUSH, op_addr=0x1000 + n))
    assert b.model.count == depth
    for _ in range(depth):
        await b.step(Inputs(op_valid=True, op=POP))
    assert b.model.count == 0

    await b.step(Inputs(op_valid=True, op=PUSH, op_addr=0xA))
    saved = b.model.checkpoint()
    await b.step(Inputs(op_valid=True, op=PUSH, op_addr=0xBAD))
    # Recovery wins over a simultaneous ordinary push. Its done ID is
    # visible before the edge; the repaired top appears only after it.
    await b.step(Inputs(op_valid=True, op=PUSH, op_addr=0xDEAD,
                        recover=True, recover_id=7, ckpt=saved, fix=NONE))
    assert b.model.checkpoint() == saved
    await b.step(Inputs(recover=True, recover_id=8, ckpt=saved,
                        fix=POP_PUSH, fix_addr=0xFACE))
    assert b.model.checkpoint().addr == 0xFACE

    # An old request can be replaced before its sampling edge. Only the
    # winner presented at the edge writes state; identity follows that winner.
    old = Inputs(recover=True, recover_id=9, ckpt=saved, fix=PUSH, fix_addr=0x999)
    new = Inputs(recover=True, recover_id=10, ckpt=saved, fix=PUSH, fix_addr=0xAAA)
    b.drive(old)
    await Timer(1, unit="ns")
    b.check(old, "old candidate before replacement")
    b.drive(new)
    await Timer(1, unit="ns")
    b.check(new, "new winner before edge")
    b.d.clk_i.value = 1
    b.model.advance(new)
    await Timer(1, unit="ns")
    b.check(new, "new winner after edge")
    b.d.clk_i.value = 0
    await Timer(1, unit="ns")
    b.cycle += 1
    assert b.model.checkpoint().addr == 0xAAA

    # Depth one forces repair and corrected push to write the same entry.
    if depth == 1:
        await b.step(Inputs(recover=True, recover_id=11, ckpt=saved,
                            fix=PUSH, fix_addr=0xABC))
        assert b.model.checkpoint().addr == 0xABC
    if depth >= 3:
        await b.step(Inputs(reset=True))
        for addr in (0xA, 0xB, 0xC):
            await b.step(Inputs(op_valid=True, op=PUSH, op_addr=addr))
        saved = b.model.checkpoint()
        for action, addr in ((POP, 0), (POP, 0), (PUSH, 0x58), (PUSH, 0x59)):
            await b.step(Inputs(op_valid=True, op=action, op_addr=addr))
        await b.step(Inputs(recover=True, recover_id=12, ckpt=saved))
        assert b.model.checkpoint().addr == 0xC
        await b.step(Inputs(op_valid=True, op=POP))
        # D29 intentionally repairs only the saved top; B was overwritten by X.
        assert b.model.checkpoint().addr == 0x58


@cocotb.test()
async def randomized_transactions(dut):
    b = await fresh(dut)
    seed = int(os.environ.get("TEST_SEED", "1"), 0)
    rng = random.Random(seed)
    checkpoints = [b.model.checkpoint()]
    for _ in range(800):
        if rng.random() < 0.015:
            inp = Inputs(reset=True)
            checkpoints = []
        else:
            recover = rng.random() < 0.22 and bool(checkpoints)
            inp = Inputs(
                op_valid=rng.random() < 0.8,
                op=rng.randrange(4),
                op_addr=rng.getrandbits(len(dut.op_push_addr_i)),
                recover=recover,
                recover_id=rng.getrandbits(len(dut.recover_id_i)),
                ckpt=rng.choice(checkpoints) if recover else Checkpoint(0, 0, 0),
                fix=rng.randrange(4),
                fix_addr=rng.getrandbits(len(dut.recover_push_addr_i)),
            )
        await b.step(inp)
        checkpoints.append(b.model.checkpoint())
        if len(checkpoints) > 48:
            checkpoints.pop(0)
    dut._log.info("RAS random PASS: depth=%d seed=%#x cycles=%d", b.model.depth,
                  seed, b.cycle)
