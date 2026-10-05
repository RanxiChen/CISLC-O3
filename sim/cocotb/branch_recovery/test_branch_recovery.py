import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

from branch_recovery_model import expected_redirect, is_link_register


async def cycle(dut):
    await RisingEdge(dut.clk_i)
    await ReadOnly()
    # Leave cocotb's read-only sampling phase before the caller drives the
    # next-cycle inputs.  Cocotb 2.x rejects writes made directly from it.
    await Timer(1, unit="ps")


def clear_inputs(dut):
    for name in (
        "exec_valid_i", "exec_mispredict_i", "exec_ftq_idx_i", "exec_ftq_gen_i",
        "exec_slot_i", "exec_branch_pc_i", "exec_inst_len_i", "exec_cfi_type_i",
        "exec_ras_action_i", "exec_actual_taken_i", "exec_actual_target_i",
        "exec_redirect_pc_i", "history_done_i", "ras_done_i", "ras_done_idx_i",
        "ras_done_gen_i", "bu_issue_valid_i", "bu_read_grant_i", "bu_pc_i",
        "bu_pred_next_i", "bu_inst_len_i", "bu_ftq_idx_i", "bu_ftq_gen_i",
        "bu_slot_i", "bu_is_branch_i", "bu_is_jal_i", "bu_cond_i",
        "bu_imm_type_i", "bu_imm_raw_i", "bu_rs1_en_i", "bu_rs2_en_i",
        "bu_rd_i", "bu_rd_write_i", "bu_src1_i", "bu_src2_i",
        "bu_result_consume_i", "fb_enq_valid_i", "fb_kill_i",
        "alu_read_grant_i", "alu_result_consume_i", "alu_issue_branch_mask_i",
        "alu_issue_rob_i", "alu_resolution_valid_i",
        "alu_resolution_mispredict_i", "alu_resolution_tag_i",
    ):
        getattr(dut, name).value = 0


async def reset(dut):
    clear_inputs(dut)
    dut.rst_i.value = 1
    await cycle(dut)
    await cycle(dut)
    dut.rst_i.value = 0
    await Timer(1, unit="ns")


@cocotb.test()
async def direct_control_recovery_contract(dut):
    """Directed contracts plus a fixed-seed set of taken branch metadata cases."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    seed = int(os.environ.get("TEST_SEED", "1"))
    rng = random.Random(seed)

    # BRU: direct JAL produces one resolution pulse even while its link result
    # remains backpressured, and carries the dynamic FTQ metadata unchanged.
    await reset(dut)
    pc = 0x100
    target = 0x108
    dut.bu_issue_valid_i.value = 1
    dut.bu_read_grant_i.value = 1
    dut.bu_pc_i.value = pc
    dut.bu_pred_next_i.value = pc + 4
    dut.bu_inst_len_i.value = 4
    dut.bu_ftq_idx_i.value = 3
    dut.bu_ftq_gen_i.value = 1
    dut.bu_slot_i.value = 5
    dut.bu_is_jal_i.value = 1
    dut.bu_imm_type_i.value = 5  # IMM_TYPE_J
    dut.bu_imm_raw_i.value = target - pc
    dut.bu_rd_i.value = 1
    dut.bu_rd_write_i.value = 1
    dut.bu_result_consume_i.value = 1
    await cycle(dut)
    dut.bu_issue_valid_i.value = 0
    dut.bu_read_grant_i.value = 0
    await cycle(dut)
    assert int(dut.bu_resolve_valid_o.value) == 1, f"seed={seed}: missing JAL resolution"
    assert int(dut.bu_resolve_mispredict_o.value) == 1
    assert int(dut.bu_resolve_slot_o.value) == 5
    assert int(dut.bu_resolve_cfi_o.value) == 2  # CFI_JAL
    assert int(dut.bu_resolve_ras_o.value) == int(is_link_register(1))
    assert int(dut.bu_resolve_target_o.value) == target
    assert int(dut.bu_resolve_redirect_o.value) == target
    dut.bu_result_consume_i.value = 0
    await cycle(dut)
    assert int(dut.bu_resolve_valid_o.value) == 0, f"seed={seed}: repeated resolution"

    # Redirect R0 emits a same-cycle kill/new PC, R1 holds the whole request,
    # and only matching history/RAS completion releases recovery for R2.
    dut.exec_valid_i.value = 1
    dut.exec_mispredict_i.value = 1
    dut.exec_ftq_idx_i.value = 3
    dut.exec_ftq_gen_i.value = 1
    dut.exec_slot_i.value = 5
    dut.exec_branch_pc_i.value = pc
    dut.exec_inst_len_i.value = 4
    dut.exec_cfi_type_i.value = 1  # CFI_BR
    dut.exec_actual_taken_i.value = 1
    dut.exec_actual_target_i.value = target
    dut.exec_redirect_pc_i.value = expected_redirect(pc, 4, target, True)
    await Timer(1, unit="ns")
    assert int(dut.kill_valid_o.value) == 1
    assert int(dut.bpu_redirect_valid_o.value) == 1
    assert int(dut.bpu_redirect_pc_o.value) == target
    assert int(dut.snap_req_o.value) == 1
    await cycle(dut)
    dut.exec_valid_i.value = 0
    assert int(dut.recover_busy_o.value) == 1
    assert int(dut.winner_target_o.value) == target
    assert int(dut.winner_hist_inject_o.value) == 1
    dut.history_done_i.value = 1
    dut.ras_done_i.value = 1
    dut.ras_done_idx_i.value = 4  # wrong identity must not release
    dut.ras_done_gen_i.value = 1
    await cycle(dut)
    assert int(dut.recover_busy_o.value) == 1
    dut.ras_done_idx_i.value = 3
    await cycle(dut)
    assert int(dut.recover_busy_o.value) == 0
    dut.history_done_i.value = 0
    dut.ras_done_i.value = 0

    # Execution redirects can clear the entire not-yet-delivered fetch buffer.
    dut.fb_enq_valid_i.value = 1
    await cycle(dut)
    dut.fb_enq_valid_i.value = 0
    assert int(dut.fb_deq_valid_o.value) == 1
    dut.fb_kill_i.value = 1
    await cycle(dut)
    dut.fb_kill_i.value = 0
    assert int(dut.fb_deq_valid_o.value) == 0

    # Fixed-seed metadata sanity: all generated taken targets use the model's
    # target rather than the fallthrough. This keeps failures reproducible.
    for _ in range(16):
        rand_pc = rng.randrange(0x200, 0x1000, 4)
        rand_target = rng.randrange(0x200, 0x1000, 4)
        assert expected_redirect(rand_pc, 4, rand_target, True) == rand_target


@cocotb.test()
async def older_result_backpressure_kills_younger_regread(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    seed = int(os.environ.get("TEST_SEED", "1"))
    # B12 hazard: an old held result backpressures a younger RegRead entry.
    # A matching misprediction must clear valid before it can execute later.
    await reset(dut)
    dut.alu_result_consume_i.value = 1
    dut.alu_read_grant_i.value = 1
    dut.alu_issue_rob_i.value = 1
    dut.alu_issue_branch_mask_i.value = 0
    await cycle(dut)  # old ALU uop enters RegRead
    dut.alu_issue_rob_i.value = 2
    dut.alu_issue_branch_mask_i.value = 1
    await cycle(dut)  # old result appears; younger uop enters RegRead
    assert int(dut.alu_result_valid_o.value) == 1
    assert int(dut.alu_result_rob_o.value) == 1
    assert int(dut.alu_regread_valid_o.value) == 1
    dut.alu_read_grant_i.value = 0
    dut.alu_result_consume_i.value = 0
    dut.alu_resolution_valid_i.value = 1
    dut.alu_resolution_mispredict_i.value = 1
    dut.alu_resolution_tag_i.value = 0
    await cycle(dut)
    assert int(dut.alu_regread_valid_o.value) == 0, f"seed={seed}: killed RegRead survived"
    assert int(dut.alu_result_valid_o.value) == 1
    dut.alu_resolution_valid_i.value = 0
    dut.alu_result_consume_i.value = 1
    await cycle(dut)
    assert int(dut.alu_result_valid_o.value) == 0, f"seed={seed}: killed uop reached Result"



@cocotb.test()
async def seeded_dut_alu_backpressure_resolution_lifecycle(dut):
    """Two-stage transaction model: arbitrary holds, every tag, C/M and kills."""
    cocotb.start_soon(Clock(dut.clk_i,10,unit='ns').start())
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    await reset(dut)
    rr=None;res=None;tags=len(dut.alu_issue_branch_mask_i);serial=0;holds=kills=correct=0
    for n in range(700):
        r=rng.randrange(3)==0;mis=bool(rng.randrange(2));tag=n%tags
        bit=1<<tag
        def killed(e):return e is not None and r and mis and bool(e[1]&bit)
        def cleaned(e):return (e[0],e[1]&~bit) if e is not None and r else e
        # Consume means permission to advance, as granted by WB arbiter.
        consume=res is None or killed(res) or bool(rng.randrange(3)==0)
        ready=rr is None or consume
        grant=ready and not(r and mis) and bool(rng.randrange(2))
        serial=(serial+1)%(1<<len(dut.alu_issue_rob_i))
        incoming=(serial,rng.getrandbits(tags))
        dut.alu_read_grant_i.value=int(grant)
        dut.alu_issue_rob_i.value=incoming[0];dut.alu_issue_branch_mask_i.value=incoming[1]
        dut.alu_result_consume_i.value=int(consume)
        dut.alu_resolution_valid_i.value=int(r);dut.alu_resolution_mispredict_i.value=int(mis);dut.alu_resolution_tag_i.value=tag
        holds+=res is not None and not consume;kills+=killed(rr);correct+=r and not mis
        nxt_res=(None if killed(rr) else cleaned(rr)) if consume else cleaned(res)
        nxt_rr=None if killed(rr) else (cleaned(incoming) if grant else None) if ready else cleaned(rr)
        await cycle(dut);rr,res=nxt_rr,nxt_res
        actual_rr=bool(int(dut.alu_regread_valid_o.value));actual_res=bool(int(dut.alu_result_valid_o.value))
        assert actual_rr==(rr is not None) and actual_res==(res is not None),(seed,n,rr,res,actual_rr,actual_res)
        if rr:
            assert (int(dut.alu_regread_rob_o.value),int(dut.alu_regread_mask_o.value))==rr,(seed,n,rr)
        if res:
            assert (int(dut.alu_result_rob_o.value),int(dut.alu_result_mask_o.value))==res,(seed,n,res)
    assert holds>0 and kills>0 and correct>0,(seed,holds,kills,correct)
