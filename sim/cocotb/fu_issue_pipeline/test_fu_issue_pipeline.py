"""Transaction model: a two-slot pending FIFO, an elastic operand entry, and a MEM pulse.
No combinational fall-through; data is sampled only when the read transaction fires.
"""
import os
import random
import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def independent_buffer_and_regread(dut):
    seed = int(os.environ.get("TEST_SEED", "1"))
    rng = random.Random(seed)
    pending = []
    operand = mem_pulse = None
    cycle = 0
    await Timer(1, unit="ns")
    rob_entries = int(dut.rob_entries_o.value)

    def value(name):
        return int(getattr(dut, name).value)

    async def step(**inputs):
        nonlocal pending, operand, mem_pulse, cycle
        defaults = dict(rst=0, flush_i=0, enq_valid_i=0, read_permission_i=1,
                        data_ready_i=1, fu_ready_i=1, correct_i=0, kill_i=0,
                        sequence_i=cycle + 1, mask_i=0,
                        src1_i=rng.getrandbits(64), src2_i=rng.getrandbits(64),
                        src3_i=rng.getrandbits(64))
        defaults.update(inputs)
        # IQ filters killed instructions before enqueue; generate legal admission.
        if defaults["kill_i"]:
            defaults["mask_i"] &= ~1
        dut.clk.value = 0
        for key, val in defaults.items():
            getattr(dut, key).value = val
        await Timer(2, unit="ns")
        active = not (defaults["rst"] or defaults["flush_i"])
        kill = defaults["kill_i"]
        resolve = kill or defaults["correct_i"]

        def live(item):
            return active and item is not None and not (kill and item[1] & 1)

        def resolved(item):
            if item is None:
                return None
            return (item[0], item[1] & ~1 if resolve else item[1], *item[2:])

        head = pending[0] if pending else None
        b_live, r_live, m_live = live(head), live(operand), live(mem_pulse)
        # Killed RegRead entries can be replaced even while FU is blocked.
        rr_ready = active and (operand is None or defaults["fu_ready_i"] or (kill and operand[1] & 1))
        read = bool(b_live and rr_ready and defaults["read_permission_i"] and defaults["data_ready_i"])
        enq_ready = bool(active and len(pending) < 2)
        context = f"seed={seed} cycle={cycle} inputs={defaults}"
        assert value("buffer_valid_o") == bool(b_live), context
        assert value("enq_ready_o") == enq_ready, context
        assert value("read_fire_o") == read, context
        for domain in ("mdu", "fp"):
            assert value(domain + "_valid_o") == bool(r_live), context
            if r_live:
                assert value(domain + "_rob_o") == operand[0] % rob_entries, context
                assert value(domain + "_mask_o") == resolved(operand)[1], context
                assert value(domain + "_src1_o") == operand[2], context
                assert value(domain + "_src2_o") == operand[3], context
        if r_live:
            assert value("fp_src3_o") == operand[4], context
        if b_live:
            assert value("buffer_sequence_o") == head[0], context
            assert value("buffer_mask_o") == resolved(head)[1], context
        assert value("mem_valid_o") == bool(m_live), context
        if m_live:
            assert value("mem_rob_o") == mem_pulse[0] % rob_entries, context
            assert value("mem_mask_o") == resolved(mem_pulse)[1], context
            assert value("mem_src1_o") == mem_pulse[2], context
            assert value("mem_src2_o") == mem_pulse[3], context
            assert value("atomic_o") == 1, context

        old_pending = resolved(head)
        if not active:
            pending = []
            operand = mem_pulse = None
        else:
            pending = [resolved(item) for i, item in enumerate(pending)
                       if not (kill and item[1] & 1) and not (i == 0 and read)]
            if defaults["enq_valid_i"] and enq_ready:
                pending.append((defaults["sequence_i"], defaults["mask_i"] & ~1 if resolve else defaults["mask_i"]))
            if read:
                operand = (*old_pending[:2], defaults["src1_i"], defaults["src2_i"], defaults["src3_i"])
            elif (kill and operand is not None and operand[1] & 1) or (r_live and defaults["fu_ready_i"]):
                operand = None
            else:
                operand = resolved(operand)
            mem_pulse = (*old_pending[:2], defaults["src1_i"], defaults["src2_i"], defaults["src3_i"]) if read else None
        dut.clk.value = 1
        await Timer(2, unit="ns")
        cycle += 1

    await step(rst=1)
    # Early notice permits enqueue, but absent data blocks the read for many cycles.
    await step(enq_valid_i=1, sequence_i=11, mask_i=1, data_ready_i=0)
    for _ in range(4):
        await step(enq_valid_i=1, sequence_i=99, data_ready_i=0)
    await step(read_permission_i=0)
    await step(src1_i=101, src2_i=202, src3_i=303)
    for _ in range(3):
        await step(fu_ready_i=0)
    await step(fu_ready_i=0, correct_i=1)
    await step(fu_ready_i=0, kill_i=1)  # resolved older entry survives
    await step()
    await step(enq_valid_i=1, mask_i=1)
    await step(enq_valid_i=1, mask_i=0)
    await step(kill_i=1, fu_ready_i=0)  # younger RR killed; older buffered entry replaces
    await step(flush_i=1)
    for _ in range(400):
        await step(enq_valid_i=rng.randrange(2), read_permission_i=rng.randrange(2),
                   data_ready_i=rng.randrange(2), fu_ready_i=rng.randrange(2),
                   mask_i=rng.randrange(4), kill_i=rng.randrange(15) == 0,
                   correct_i=rng.randrange(12) == 0, flush_i=rng.randrange(50) == 0,
                   rst=rng.randrange(80) == 0)
    for _ in range(8):
        await step()
