"""Full LQ output comparison with legal occupancy, refill, wake and recovery."""
import os
import random
import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def load_queue_full_output_equivalence(dut):
    rng = random.Random(int(os.environ.get('TEST_SEED', '1')))
    dut.clk_i.value = 0
    dut.rst_i.value = 1
    dut.stim_i.value = 0
    await Timer(2, unit='ns')
    masks = {k: int(getattr(dut, 'fmt_'+k).value)
             for k in ('valid', 'clear_dense', 'quiet', 'robs', 'kill', 'reset', 'release', 'alloc_one')}
    dut.stim_i.value = masks['reset']
    for _ in range(3):
        dut.clk_i.value = 1
        await Timer(2, unit='ns')
        dut.clk_i.value = 0
        await Timer(2, unit='ns')
    dut.rst_i.value = 0
    for cycle in range(6000):
        phase = cycle % 128
        stimulus = rng.getrandbits(len(dut.stim_i)) & ~masks['quiet']
        if phase < 4:
            # Four legal allocations per cycle fill the default 16-entry LQ.
            stimulus = (stimulus & ~masks['clear_dense']) | masks['valid']
        elif phase < 126:
            # Release one entry, then refill it on the following cycle. This
            # rotates head/tail through every bank without borrowing a slot.
            stimulus |= masks['release'] if phase % 2 == 0 else masks['alloc_one']
        elif phase == 126:
            # Captured masks create arbitrary holes; the next flush starts a
            # fresh legal allocation epoch while retaining generation history.
            stimulus |= masks['robs']
        elif phase == 127:
            stimulus |= masks['kill']
        dut.stim_i.value = stimulus
        await Timer(2, unit='ns')
        dut.clk_i.value = 1
        await Timer(2, unit='ns')
        dut.clk_i.value = 0
    dut.stim_i.value = 0
    for _ in range(3):
        await Timer(2, unit='ns')
        dut.clk_i.value = 1
        await Timer(2, unit='ns')
        dut.clk_i.value = 0
