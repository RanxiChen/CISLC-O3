# Branch Mispredict Flush Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a minimal, precise branch-mispredict redirect path so a taken conditional branch resolved in the backend can flush younger frontend work, preserve ICache contents, repair the affected FTQ block, and restart prediction/fetch from the redirect PC.

**Architecture:** The first implementation only supports the currently existing branch model: conditional branch, frontend predicts not-taken, backend detects taken and issues redirect. Redirect is carried as a unified packet from backend to frontend. Frontend applies the redirect by clearing transient IFU/fetch-buffer state, invalidating younger FTQ entries, truncating the branch-holding FTQ block, and reseeding BPU from the redirect PC.

**Tech Stack:** SystemVerilog RTL, existing `frontend`/`backend`/`o3_core` integration, current FTQ/BPU/IFU/fetch-buffer structures, existing frontend and single-core smoke regressions.

---

## Expected End State

After this plan is fully executed, the design should behave as follows:

1. A conditional branch that resolves as taken in `branch_execute_unit` generates a redirect event carrying at least `ftq_idx`, `branch_pc`, `redirect_pc`, and direction/result metadata.
2. The redirect event reaches `frontend` through `backend` and `o3_core`.
3. `frontend` flushes transient wrong-path state:
   - clears IFU in-flight block/S1/S2 state
   - clears fetch-buffer queued wrong-path instructions
   - does **not** clear ICache contents or refill state unrelated to correctness
4. `FTQ` repairs control-flow history:
   - invalidates all entries younger than the branch-containing block
   - keeps older entries unchanged
   - truncates the branch-containing block so its `end_pc` becomes `branch_pc + 4`
   - updates that block’s `next_pc` to the actual redirect target
5. `BPU` accepts the redirect PC and resumes block generation from that PC instead of continuing the old sequential stream.
6. Existing docs and smoke tests reflect the new redirect/flush behavior and current limitations.
7. A directed core-level branch test proves that wrong-path instructions do not retire and redirect-target instructions do retire.
8. Backend performs same-cycle recovery on branch mispredict: younger backend work is squashed immediately, rename/free-list state is restored from the branch checkpoint, and only older work plus the branch itself survives.

## Constraints For This Short-Term Plan

- Only support the currently implemented branch class: conditional branch in `branch_execute_unit`.
- Only support the current prediction model: frontend predicts not-taken, backend resolves taken => mispredict.
- Do not attempt generalized exception recovery or a final multi-cause rollback architecture in this step; only implement the minimal branch-mispredict recovery path described here.
- Distinguish clearly between:
  - `invalidate wrong path now`
  - `release FTQ capacity later at retire/commit`
- Backend recovery is **same-cycle** with branch resolution for this milestone:
  - branch execute combinationally detects mispredict
  - that same cycle’s state update must squash younger backend work
  - that same cycle’s state update must restore rename/free-list checkpoint state
- In the mispredict cycle:
  - older-than-branch writeback/complete/retire effects may survive
  - the branch itself survives
  - younger-than-branch writeback/complete/retire effects must be killed immediately
- Module-boundary policy for this milestone:
  - `rename_map_table.sv` gets a direct full-table checkpoint recover input
  - `free_list.sv` gets direct recover inputs for checkpointed `head/tail/count`
  - `rob.sv` gets a direct younger-squash input keyed by branch `rob_idx`
  - other backend queues/pipeline registers should be squashed primarily in `backend.sv` top-level logic by killing valids and suppressing side effects, instead of adding broad new child-module interfaces
- The checkpoint table policy is fixed for this milestone:
  - fixed capacity: 4
  - allocate the first free checkpoint slot
  - at most one new branch checkpoint may be allocated per rename group
- Existing `sim/core_three_alu/tests/three_alu_branch.cpp` remains a required branch-metadata regression after the recovery path lands.
- Preserve current design style and update `doc/CISLC_O3_frontend.md`, `doc/CISLC_O3.md`, and module headers when behavior changes.

## File Structure

**Files to modify:**
- `rtl/backend/branch_execute_unit.sv`
- `rtl/backend/backend.sv`
- `rtl/backend/free_list.sv`
- `rtl/backend/rename_map_table.sv`
- `rtl/backend/rob.sv`
- `rtl/frontend/bpu.sv`
- `rtl/frontend/ftq.sv`
- `rtl/frontend/ifu.sv`
- `rtl/frontend/fetch_buffer.sv`
- `rtl/frontend/frontend.sv`
- `rtl/core/o3_core.sv`
- `rtl/common/o3_pkg.sv`
- `doc/CISLC_O3_frontend.md`
- `doc/CISLC_O3.md`

**Files likely to inspect while implementing:**
- `agent.md`
- `doc/ftq.md`
- `tb/frontend_testharness.sv`
- `sim/frontend/tests/frontend_basic.cpp`
- `sim/core_single_inst/*`

### Task 1: Freeze Redirect Scope And Packet Shape

**Files:**
- Modify: `rtl/common/o3_pkg.sv` if shared type is introduced
- Modify: `doc/CISLC_O3_frontend.md`
- Modify: `doc/CISLC_O3.md`

- [ ] **Step 1: Define the short-term redirect contract**

Write down the exact fields for the first redirect packet:
- `valid`
- `ftq_idx`
- `branch_pc`
- `redirect_pc`
- `actual_taken`
- optional: `fallthrough_pc`

- [ ] **Step 2: Define redirect ownership**

Document that:
- backend detects mispredict
- core transports redirect
- frontend consumes redirect
- FTQ repairs block/window state
- BPU reseeds prediction stream

- [ ] **Step 3: Record current limitation**

Document explicitly that this version only handles `pred not-taken / actual taken` conditional branches.

- [x] **Step 4: Commit**

```bash
git add rtl/common/o3_pkg.sv doc/CISLC_O3_frontend.md doc/CISLC_O3.md
git commit -m "docs: define branch redirect contract"
```

### Task 2: Modify BPU To Accept Redirect Reseed

**Files:**
- Modify: `rtl/frontend/bpu.sv`
- Modify: `doc/CISLC_O3_frontend.md`

- [ ] **Step 1: Add redirect input port to BPU**

Add inputs conceptually equivalent to:
- `redirect_valid_i`
- `redirect_pc_i`

- [ ] **Step 2: Change BPU state update priority**

Define sequential behavior:
- reset: `pred_pc_q <= reset_pc_i`
- redirect: `pred_pc_q <= redirect_pc_i`
- normal enqueue fire: `pred_pc_q <= pred_pc_q + FTQ_BLOCK_BYTES`

Redirect must take priority over normal enqueue advance.

- [ ] **Step 3: Keep BPU responsibility minimal**

Do **not** make BPU rewrite old FTQ entries. BPU only reseeds future prediction origin.

- [ ] **Step 4: Update module header and timing comments**

Explain that redirect overrides sequential generation and restarts block prediction from the supplied PC.

- [ ] **Step 5: Commit**

```bash
git add rtl/frontend/bpu.sv doc/CISLC_O3_frontend.md
git commit -m "feat: add bpu redirect reseed"
```

### Task 3A: Add FTQ Redirect Repair Interface

**Files:**
- Modify: `rtl/frontend/ftq.sv`

- [ ] **Step 1: Add redirect repair port to FTQ**

Add a redirect input carrying at least:
- redirect valid
- branch `ftq_idx`
- `branch_pc`
- `redirect_pc`
- actual direction

- [ ] **Step 2: Define redirect priority and ownership inside FTQ**

Document and implement the local rule that redirect repair is a correctness event with higher priority than normal enqueue/consume updates for the affected slots.

- [ ] **Step 3: Keep the new interface minimal**

Do not add backend-specific recovery policy into FTQ. The FTQ redirect input is only for repairing frontend block history.

- [x] **Step 4: Commit**

```bash
git add rtl/frontend/ftq.sv
git commit -m "feat: add ftq redirect repair interface"
```

### Task 3B: Repair FTQ Entries For Redirect

**Files:**
- Modify: `rtl/frontend/ftq.sv`

- [x] **Step 1: Implement younger-entry invalidation**

For every allocated entry younger than the branch-containing FTQ entry:
- clear `entry.valid`
- keep allocation state for now unless the chosen implementation also rewinds alloc-tail safely

This is correctness repair, not final resource release.

- [x] **Step 2: Repair the branch-containing entry**

Update the matching FTQ entry so that:
- `end_pc = branch_pc + 4`
- `next_pc = redirect_pc`
- if useful for debug, update `pred_taken/target_pc/fallthrough_pc` consistently

- [x] **Step 3: Keep older entries unchanged**

Do not perturb any FTQ entry older than the branch-containing block.

- [x] **Step 4: Commit**

```bash
git add rtl/frontend/ftq.sv
git commit -m "feat: repair ftq entries on redirect"
```

### Task 3C: Rewind FTQ Window State Safely

**Files:**
- Modify: `rtl/frontend/ftq.sv`
- Modify: `doc/ftq.md`
- Modify: `doc/CISLC_O3_frontend.md`

- [ ] **Step 1: Define pointer policy**

Choose and document one minimal safe policy for first implementation:
- recommended: rewind `ifu_head_q` only if needed for correctness, otherwise rely on IFU flush and validity bits
- recommended: move `alloc_tail_q` to the slot after the repaired branch entry so future BPU blocks overwrite old wrong-path window

Whichever policy is chosen, update `allocated_count_q` rules so FTQ does not deadlock or expose stale full-state behavior.

- [ ] **Step 2: Implement pointer/count update**

Update `alloc_tail_q`, `ifu_head_q`, and `allocated_count_q` consistently with the chosen policy so the post-redirect window can accept fresh blocks again without corrupting older retained history.

- [ ] **Step 3: Preserve release semantics**

Do not conflate wrong-path invalidation with commit-time release. Keep `release_head_q` as the future capacity-recovery mechanism.

- [ ] **Step 4: Update FTQ comments and docs**

Document:
- redirect repair behavior
- younger/older/containing-block policy
- difference between invalidate and release

- [ ] **Step 5: Commit**

```bash
git add rtl/frontend/ftq.sv doc/ftq.md doc/CISLC_O3_frontend.md
git commit -m "feat: rewind ftq window after redirect"
```

### Task 3D: Document FTQ Redirect Semantics

**Files:**
- Modify: `doc/ftq.md`
- Modify: `doc/CISLC_O3_frontend.md`

- [ ] **Step 1: Update FTQ-facing docs**

Describe the final short-term redirect semantics in one place that a later agent can resume from without reverse-engineering RTL:
- redirect input fields
- branch-entry repair rule
- younger-entry invalidation rule
- pointer/count policy
- invalidate vs release distinction

- [ ] **Step 2: Cross-check docs against RTL scope**

Make sure the docs do not claim commit-time release, generalized recovery, or backend-driven FTQ walkback that this milestone does not implement.

- [ ] **Step 3: Commit**

```bash
git add doc/ftq.md doc/CISLC_O3_frontend.md
git commit -m "docs: record ftq redirect repair semantics"
```

### Task 4: Flush IFU And Fetch Buffer Precisely

**Files:**
- Modify: `rtl/frontend/ifu.sv`
- Modify: `rtl/frontend/fetch_buffer.sv`
- Modify: `rtl/frontend/frontend.sv`
- Modify: `doc/CISLC_O3_frontend.md`

- [ ] **Step 1: Add redirect/flush handling into IFU**

On redirect:
- clear `current_block_q`
- clear `block_valid_q`
- clear S1 valid state
- clear S2 slot valid/data-valid state

Do not touch ICache contents here.

- [ ] **Step 2: Ensure stale ICache returns are dropped**

If an old request returns after redirect, IFU must not emit those instructions to fetch-buffer. The simplest first version is to clear all in-flight S2 context on redirect.

- [ ] **Step 3: Extend fetch_buffer flush use**

Make frontend use redirect to flush queued wrong-path entries from fetch-buffer.

- [ ] **Step 4: Wire redirect through frontend top**

`frontend.sv` must distribute redirect to:
- BPU
- FTQ
- IFU
- fetch_buffer flush path

- [ ] **Step 5: Keep ICache policy explicit**

Document that redirect flushes control state only; ICache arrays/state are intentionally preserved.

- [ ] **Step 6: Commit**

```bash
git add rtl/frontend/ifu.sv rtl/frontend/fetch_buffer.sv rtl/frontend/frontend.sv doc/CISLC_O3_frontend.md
git commit -m "feat: flush ifu and fetch buffer on redirect"
```

### Task 5: Add Same-Cycle Backend Recovery And Export Redirect

**Files:**
- Modify: `rtl/common/o3_pkg.sv`
- Modify: `rtl/backend/branch_execute_unit.sv`
- Modify: `rtl/backend/backend.sv`
- Modify: `rtl/backend/free_list.sv`
- Modify: `rtl/backend/rename_map_table.sv`
- Modify: `rtl/backend/rob.sv`
- Modify: `rtl/core/o3_core.sv`
- Modify: `doc/CISLC_O3.md`
- Modify: `doc/CISLC_O3_frontend.md`

- [ ] **Step 1: Extend backend branch metadata path**

Confirm the branch path preserves all redirect/recovery metadata deep enough into branch execution. For the first implementation this must include at least:
- `ftq_idx`
- `rob_idx`
- `branch_pc`

If the current path drops any of these fields, add them to the relevant backend uop / branch pipeline structs in `rtl/common/o3_pkg.sv` and wire them through decode/rename/branch-issue/regread/execute.

- [ ] **Step 2: Add a small branch checkpoint table in `backend.sv`**

Implement a fixed small checkpoint structure in `backend.sv` for short-term recovery:
- fixed capacity: 4 checkpoints is sufficient for this milestone
- one rename group may allocate **at most one** new branch checkpoint
- if a rename group contains more than one branch, block rename and add a simulation-time assertion
- if the checkpoint table is full, block the whole rename group
- choose the checkpoint slot by taking the first free entry

Each valid checkpoint entry should hold at least:
- `branch_rob_idx`
- `branch_pc`
- rename map snapshot
- free-list recovery state:
  - `head`
  - `tail`
  - `count`

Also add backend-local ROB association arrays:
- `rob_has_checkpoint[rob_idx]`
- `rob_checkpoint_id[rob_idx]`

The checkpoint id may simply be the checkpoint-table index.

- [ ] **Step 3: Create branch-time checkpoint allocation**

On the cycle a branch rename actually fires:
- allocate one checkpoint id
- snapshot rename-map state
- snapshot free-list recovery state
- record `rob_has_checkpoint` / `rob_checkpoint_id` for the branch ROB entry

Document that checkpoint allocation is aligned with actual rename/ROB allocation, not with decode-only branch recognition.

- [ ] **Step 4: Upgrade `free_list` for precise branch recovery**

Refactor `rtl/backend/free_list.sv` from implicit-tail behavior into explicit state:
- `head_q`
- `tail_q`
- `count_q`

Add direct recovery ports so backend can restore checkpointed free-list state in the mispredict cycle.

On a same-cycle recover:
- load checkpointed `head/tail/count`
- append only **older-than-branch** retire releases to the restored tail
- do not allow younger release effects through
- do not allow normal alloc consumption through that cycle

The surviving releases should come from the existing `rob_retire_*` outputs after backend top-level age filtering.

Keep this module self-contained: backend computes recovery inputs; `free_list` performs the final “restore checkpoint + append surviving older releases” state update.

- [ ] **Step 5: Add rename-map checkpoint restore**

Add a direct recovery input path to `rtl/backend/rename_map_table.sv` so backend can restore the branch checkpointed mapping in the mispredict cycle.

This milestone uses full checkpoint restore, not incremental per-entry rollback. Keep the implementation simple and explicit.

- [ ] **Step 6: Add ROB younger-squash interface and unified ROB-age helpers**

Add a direct interface to `rtl/backend/rob.sv` for same-cycle younger squash keyed by branch `rob_idx`.

`rob.sv` should **not** restore checkpoint state. It should only:
- keep older-than-branch entries
- keep the branch entry itself
- invalidate younger-than-branch entries
- clear younger completion / retire-info sideband state consistently

Define one backend-local ROB age predicate for ring-order comparisons and reuse it everywhere recovery needs the same answer:
- ROB younger-entry invalidation
- checkpoint younger-entry release
- issue-queue younger kill
- branch-issue-queue younger kill
- execute-pipe younger kill
- writeback/complete/retire younger kill

Do **not** hand-code separate ad hoc `>` / `<` checks in multiple places.

- [ ] **Step 7: Flush younger backend state in the same mispredict cycle**

When `branch_execute_unit` detects mispredict:
- branch execute combinationally identifies the branch ROB entry and checkpoint id
- that same cycle must kill all younger backend side effects
- that same cycle’s sequential update must restore rename/free-list checkpoint state

At minimum, younger-than-branch state must be removed or suppressed from:
- fetch-entry staging inside backend
- decode / uop queue state
- integer issue queue
- branch issue queue
- integer execute pipeline registers
- branch pipeline registers
- ROB younger entries

The branch itself and all older work remain valid.

- [ ] **Step 8: Define same-cycle side-effect priority**

In the mispredict cycle:
- older-than-branch writeback / complete / retire effects may commit
- the branch’s own resolve metadata survives
- younger-than-branch writeback / complete / retire effects must be dropped

This priority must be made explicit in comments and code structure. Recovery should have the highest state-update priority after reset.

- [ ] **Step 9: Package redirect event and connect it through `o3_core`**

After backend recovery semantics are defined, package the redirect event with the agreed fields and connect:
- backend redirect output
- frontend redirect input

The redirect packet should remain the single cross-boundary recovery signal from backend to frontend.

- [ ] **Step 10: Update comments/docs**

Document:
- branch checkpoint allocation point
- same-cycle backend recovery rule
- free-list and rename-map restore behavior
- younger squash scope
- current limitations such as fixed checkpoint capacity and one-branch-per-rename-group support

- [ ] **Step 11: Commit**

```bash
git add rtl/common/o3_pkg.sv rtl/backend/branch_execute_unit.sv rtl/backend/backend.sv rtl/backend/free_list.sv rtl/backend/rename_map_table.sv rtl/backend/rob.sv rtl/core/o3_core.sv doc/CISLC_O3.md doc/CISLC_O3_frontend.md
git commit -m "feat: add backend branch recovery path"
```

### Task 6: Verification And Resume Workflow

**Files:**
- Modify: `doc/CISLC_O3_frontend.md`
- Modify: `doc/CISLC_O3.md`
- Optional: relevant testbench or sim files if redirect-focused checks are added

- [x] **Step 1: Re-run existing frontend regression**

Run:

```bash
cd sim/frontend
make clean-test TEST=frontend_basic
make test TEST=frontend_basic
```

Expected:
- existing fetch path still works
- no regression in FTQ->IFU->ICache->fetch-buffer flow

Result (2026-05-10): PASS — `frontend_basic` reports `ftq_ifu_fire_count=4 instructions_received=16` after the redirect plumbing.

- [x] **Step 2: Re-run core smoke**

Run:

```bash
cd sim/core_single_inst
make test
```

Expected:
- current single-instruction path still retires
- no compile/interface break after redirect plumbing

Result (2026-05-10): PASS — `core_single_inst` retires `addi x1, x0, 1` at cycle 20 with `retired_inst_count=1`.

- [x] **Step 3: Add at least one redirect-oriented check**

Minimum acceptable first version:
- a directed test or temporary checker that confirms a taken branch causes frontend restart from redirect PC and wrong-path fetch entries do not reach backend
- re-run the existing `sim/core_three_alu/tests/three_alu_branch.cpp`-style branch retire metadata regression so the new recovery path does not silently break current branch retire observability

Result (2026-05-10):
- New directed redirect test added at `sim/core_three_alu/tests/three_alu_redirect.cpp`. It is independent from `three_alu_branch.cpp`, which keeps its existing 4-retire branch metadata regression role.
- `three_alu_branch` regression: PASS (`retired_inst_count=4 cycles=27`).
- `three_alu_redirect` regression: FAIL on the redirect-target retire (see Findings below).

- [x] **Step 3a: Add the first directed redirect program image**

Use this exact first-version instruction layout:

- `0x00: addi x1, x0, 1`
- `0x04: addi x2, x0, 1`
- `0x08: add  x3, x1, x2`
- `0x0c: bne  x3, x2, +16`
- wrong path:
  - `0x10: ori  x4, x0, 9`
  - `0x14: xori x5, x0, 6`
  - `0x18: addi x6, x0, 7`
- redirect target path:
  - `0x1c: addi x7, x0, 11`
  - `0x20: add  x8, x7, x1`

This branch must resolve as taken because:
- `x1 = 1`
- `x2 = 1`
- `x3 = x1 + x2 = 2`
- `bne x3, x2` therefore evaluates true

- [x] **Step 3b: Define the required retire stream**

The checker must observe exactly this architecturally visible retirement sequence:

- must retire:
  - `0x00`
  - `0x04`
  - `0x08`
  - `0x0c` as branch retire with `taken=1` and `mispredict=1`
  - `0x1c`
  - `0x20`
- must never retire:
  - `0x10`
  - `0x14`
  - `0x18`

Result (2026-05-10): observed retire stream from `three_alu_redirect.cpp`:

```
[cycle=20] retire pc=0x0  rd=x1 rd_wdata=0x1 rob=0
[cycle=20] retire pc=0x4  rd=x2 rd_wdata=0x1 rob=1
[cycle=24] retire pc=0x8  rd=x3 rd_wdata=0x2 rob=2
[cycle=27] retire pc=0xc  branch taken=1 mispredict=1 target=0x1c fallthrough=0x10 rob=3
[cycle=47] retire pc=0x1c rd=x7 rd_wdata=0xb rob=4
[cycle=51] retire pc=0x20 rd=x8 rd_wdata=0x0 rob=5  <-- expected 0xc, observed 0x0
```

- Wrong-path PCs (`0x10/0x14/0x18`) never appear in `retire_info_o`. ✓
- Branch retire metadata matches plan. ✓
- Redirect-target retires happen in order at `0x1c` and `0x20`. ✓
- The `0x20` retire's architectural value is wrong (`x8=0` instead of `x8=12`); see Findings below.

- [x] **Step 3c: Implement the simulation body using current `sim/core_three_alu` style**

The first testbench implementation should:

- live under `sim/core_three_alu/tests/`
- keep the current `Vo3_core` direct simulation style
- keep the current refill-driver structure:
  - reset core
  - observe `refill_req`
  - respond after fixed latency
  - generate instruction words from `read_inst(pc)`
- keep retire-driven checking through `retire_info_o`

The test body should be structured as:

1. Define constants for the nine instructions and expected retire count.
2. Implement `read_inst(pc)` as a switch over the exact PCs above.
3. Reuse the refill queue model already used in `three_alu.cpp` / `three_alu_branch.cpp`.
4. Read `retire_info_o` every cycle.
5. Compare each observed retire against an ordered expected-retire list.
6. Immediately fail if any retired PC is one of the forbidden wrong-path PCs.
7. For the branch retire, also check:
   - `branch_taken == 1`
   - `branch_mispredict == 1`
   - `branch_target_pc == 0x1c`
   - `branch_fallthrough_pc == 0x10`
8. End the test successfully only after all required retires have been observed.
9. Fail on timeout if the expected retire stream does not complete.

Result (2026-05-10): implemented in `sim/core_three_alu/tests/three_alu_redirect.cpp`. The test reuses the existing `Vo3_core` + refill-driver loop from `three_alu_branch.cpp`, accumulates retires across cycles (rather than expecting a single-cycle wide retire), and asserts the full ordered expected list including PC, instruction, uop_type, rd/rd_write_en, rd_wdata, and branch metadata. `instruction_id` is asserted equal to lane index for the four lane-0 group retires (rob 0..3) and only required to lie in a post-redirect fetch group (`> 5`) for retires 4 and 5, since the actual fetch_group_seq value depends on how many wrong-path groups passed through `fetch_fire` before the squash.

- [x] **Step 4: Update docs with exact current behavior**

After RTL lands, update:
- redirect packet shape
- FTQ repair semantics
- BPU reseed behavior
- IFU/fetch-buffer flush behavior
- still-missing items

Result (2026-05-10): updated `doc/CISLC_O3.md` and `doc/CISLC_O3_frontend.md` to reflect the actual implementation status, with explicit notes on the same-cycle backend recovery boundary and the still-missing items (in particular the in-group RAW dependency limitation that the redirect test exposes).

- [x] **Step 5: Mark progress in this plan file**

When resuming after context loss:
- open `agent.md`
- open this plan file
- check which task and checkbox was last completed
- continue from the next unchecked step

Result (2026-05-10): this section now records pass/fail, observed retire stream, and a Findings sub-section so a later agent can resume from the in-group dependency follow-up without re-running the test.

- [x] **Step 6: Commit**

```bash
git add doc/CISLC_O3_frontend.md doc/CISLC_O3.md docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md
git commit -m "docs: record branch redirect verification status"
```

## Findings From Task 6 Verification (2026-05-10)

The directed redirect test surfaced a same-cycle checkpoint correctness limitation in the Task 5 backend recovery path. This is **not** a flaw in redirect transport, FTQ repair, BPU reseed, or IFU/fetch-buffer flush — the test confirms those work end-to-end:

- frontend re-fetches starting from `redirect_pc=0x1c` after the branch resolves taken
- wrong-path PCs `0x10/0x14/0x18` never reach retire
- the branch retire carries `taken=1 mispredict=1 target=0x1c fallthrough=0x10`

The failure is a **redirect-target value bug** at retire 5 (`pc=0x20`, `add x8, x7, x1`). Backend trace shows the renamer producing `src1:p0 src2:p1` for `add x8, x7, x1` after recovery, even though the architecturally correct mapping is `x1 -> p32` (the preg holding the just-retired `addi x1, x0, 1` result) and `x7 -> <new preg>` (the preg holding the just-retired `addi x7, x0, 11` result).

Two interacting issues:

1. **Pre-rename checkpoint snapshot.** `backend.sv` captures `rename_map_current` (= `rename_map_table.current_map_o` = `map_table_q`) and `free_list_head/tail/count` at the cycle the branch is renamed. These values reflect *start of cycle*, not the post-rename state after older same-group lanes have updated the map and consumed pregs. When the branch sits in a non-zero rename lane (lane 3 in this test), older same-group `addi` instructions update `x1/x2/x3` in the same cycle. The checkpoint therefore stores the pre-update mapping (`x1 -> p1`), and on recovery `x1` is restored to `p1` — but `p1` was already released by the surviving older retire and a different preg (`p32`) holds the architectural value of `x1`.

2. **Branch retire releases p0 to free list.** Branches set `rd_write_en=0`, so `old_dst_preg` for a branch ROB entry is `p0`. The retire path passes that through `filtered_retire_preg[port]` into `free_list.release_preg_i`, and `free_list.sv` writes `p0` into `queue_mem` at the post-recovery tail. A later allocation can hand `p0` to a real `rd`, which then silently drops its writeback because `physical_regfile` ignores writes to `p0`. In the test trace this is what gives `addi x7, x0, 11` `new:p0`.

These are both Task 5 (backend recovery) issues, not Task 6 issues, so this plan does not modify RTL to repair them. Suggested follow-up scope:

- Capture the checkpoint snapshot using the post-rename map (`map_table_next`-equivalent) and the post-allocation free-list `head/count`, restricted to lanes older-or-equal to the branch lane.
- Filter `release_valid_i` in the retire path so a release with `release_preg_i == 0` (or with `rd_write_en=0` at allocate time) does not corrupt `queue_mem`.
- Re-run `sim/core_three_alu/tests/three_alu_redirect.cpp` after the fix; the strict ordered retire-stream check is the regression criterion.

The redirect test as committed is intentionally strict so the follow-up will be obvious to the next agent; the test's `[core_three_alu_redirect][assert] rd_wdata mismatch for retire 5` line names exactly which retire slot deviates and which field to look at.

## Recommended Execution Order

1. Task 1: freeze redirect packet and scope
2. Task 2: BPU redirect reseed
3. Task 3A: FTQ redirect repair interface
4. Task 3B: FTQ entry repair
5. Task 3C: FTQ pointer/count rewind
6. Task 3D: FTQ redirect doc sync
7. Task 4: IFU/fetch-buffer flush
8. Task 5: backend same-cycle recovery + redirect plumbing
9. Task 6: verification and doc sync

## Resume Instructions

If a later agent loses context, resume with exactly this sequence:

1. Read `agent.md`
2. Read `doc/CISLC_O3_frontend.md`
3. Read `doc/CISLC_O3.md`
4. Read this file: `docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md`
5. Find the first unchecked step
6. Before editing, restate:
   - which files will change
   - why they need to change
   - which interfaces and docs are affected

## First Milestone Definition

This short-term plan is complete when:

- a taken conditional branch resolved in backend can redirect frontend ✓ (Task 5)
- backend performs same-cycle younger squash and checkpoint restore for that branch ⚠ (works for the architectural state of the branch and its older instructions; same-cycle in-group RAW dependencies between older and the branch are not yet preserved across recovery — see Task 6 Findings)
- wrong-path frontend state is flushed ✓ (Task 4)
- wrong-path backend state is flushed ✓ (Task 5; verified by `three_alu_redirect.cpp` showing `0x10/0x14/0x18` never reach retire)
- BPU restarts from redirect PC ✓ (Task 2)
- FTQ retains older history, truncates the branch block, and invalidates younger blocks ✓ (Task 3B/3C)
- the directed branch test retires `0x00/0x04/0x08/0x0c/0x1c/0x20` and never retires `0x10/0x14/0x18` ⚠ (correct PCs and order; `0x20` retires with wrong `rd_wdata` because of the same in-group RAW dependency limitation noted above)
- existing smoke tests still pass ✓ (`frontend_basic`, `core_single_inst`, `three_alu_branch` all pass after Task 5)
- docs and this plan accurately show what is done and what remains future work ✓ (Task 6 Findings + main docs updated 2026-05-10)

