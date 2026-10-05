# O3-T03：L5 M 模式 CSR 与精确异常

**直接实现，不做阶段一。**下面的决定已经由审阅确定；没写到的实现细节由实现者决定，在报告中写明（`agent.md` 第 1.2 节）。只有需要改变 Dxx/Bxx 设计决策时才停下来问。

## 目标

完成 L5（[`O3-v1-plan.md`](../O3-v1-plan.md) 第 3 节）：M 模式 CSR、精确同步异常、ECALL/EBREAK/非法指令、MRET、committed_next_pc，并让 Spike 比对覆盖 CSR 与异常。

## 已定决定

| 项目 | 决定（依据） |
| --- | --- |
| 串行化 | CSR、FENCE、FENCE.I、ECALL、EBREAK、MRET、WFI 在 Decode→Rename 边界截断同组年轻指令；串行指令自身正常 rename、进 ROB，等成为 ROB 队头且更老指令全部退休后执行，退休后才放行年轻指令（B22、B23）。实现 `rename_entry_gate`（从仓库空壳接入，B46）。 |
| CSR 执行 | 队头的单项串行通路：合法性检查（地址存在、权限、只读写入）→ 读旧值 → 按 Zicsr 规则读改写（CSRRW/RWI 在 rd=x0 时不读；CSRRS/RC 在 rs1=x0、立即数形式在 zimm=0 时不写）→ 旧值写回 rd → 退休。非法访问报非法指令异常，不更新 CSR（B22）。 |
| CSR 集合 | M 模式单 hart：`mstatus`（MIE/MPIE/MPP；MPP 只取 M）、`misa`（只读，RV64I + 本级已实现扩展）、`mie`、`mip`（外部输入本级全部为 0）、`mtvec`（direct 与 vectored 两种模式，同步异常都跳 base）、`mscratch`、`mepc`、`mcause`、`mtval`、`mhartid`=0、`mvendorid/marchid/mimpid`=0、`mcycle`、`minstret`、`cycle`/`instret`（只读影子）。未实现的 CSR 地址按非法指令处理。语义按 Breeze `design/src/main/scala/core/RegFile.scala` 的 M 模式部分（B29），只取 M 模式。 |
| 同步异常 | 指令非法、ECALL（cause 11）、EBREAK（cause 3，tval=PC）、非法指令（cause 2，tval=指令编码）、取指访问错误（来自 ICache/L2 的 error）、load/store 访问错误（来自 DCache/L2 的 error）。同 line 非对齐访问的硬件支持与跨 line 非对齐异常在 L8（B31）；本级若出现非对齐访存，按现有 LSU 行为，Spike 随机生成器继续只生成自然对齐访存。 |
| 精确提交 | ROB 队头遇异常项：先退休它之前的正常前缀；下一拍异常项为最老时触发 trap，异常项本身不退休，年轻指令全部取消。trap 拍没有正常退休（B26）。 |
| trap 入口 | `trap_ctrl` 锁存一次请求（EPC=故障指令 PC、cause、tval）；`csr_file` 更新 mepc/mcause/mtval/mstatus（MPIE←MIE、MIE←0、MPP←M），给出入口 PC；用全局恢复（committed RAT、free list 重置、ROB/LQ/SQ/IQ 清空，已提交 SQ 项保留并继续 drain）清除推测状态；N+1 拍前端从入口取指（B26）。全局恢复复用分支恢复的取消广播，但以提交边界为准。 |
| MRET | 队头正常退休时触发：恢复 MIE←MPIE、MPIE←1、MPP←M，重定向到 mepc，清除年轻路径（B27）。 |
| committed_next_pc | 提交端维护已退休前缀的下一架构 PC；trap/MRET 后更新为入口/返回目标；复位为启动地址（B37）。本级用于 EPC 的一致性检查；中断在 L11 才用到。 |
| 中断 | 本级不实现中断（没有 CLINT/PLIC），`mip` 外部位全部为 0，中断仲裁逻辑留接口并 tie-off，L11 接入。 |
| FENCE / FENCE.I | 按串行化规则在队头完成。FENCE 在 `pred.W=1` 时等 SQ drain 到空（B23）。FENCE.I 本级的最小实现：SQ drain 后全量失效 ICache 并从下一 PC 重取；L1D 脏行写回 L2 的完整序列在 L8 补齐，本级不支持自修改代码。 |
| WFI | 本级按 NOP 退休（合法，规范允许）；真正的等待在 L10。 |
| commit_ctrl | 接入仓库空壳 `commit_ctrl`，把 O3-T01 的 ROB→FTQ 最小提交通路原样并入，语义不变。 |
| 计数器 | `csr_retired`、`csr_wait_empty_cycles`、`csr_block_younger_cycles`（B22）先作为内部计数器实现，可通过 Verilator 观测；CSR 映射在 L7 统一做。 |

## Spike 比对扩展

- 退休记录填充预留字段：`csr_addr/csr_wdata`（一条 CSR 指令实际写入的 CSR 及新值）、`exc_cause/exc_tval`（trap 记录：一条特殊记录，PC=故障指令 PC，带 cause/tval，表示进入 trap 而非退休）。
- Spike 侧取相应的 commit log 信息逐条比较；`mcycle`/`cycle` 的读结果不确定，读这两个 CSR 的指令只比较目的寄存器号，不比较值（或在比对时把 DUT 的值写入 Spike，二选一）。
- 随机生成器增加：CSR 读写（mscratch、mtvec、mepc、mcause、mtval 等可写 CSR）、ECALL/EBREAK 与非法指令（带一个最小 trap handler：读 mcause/mepc，mepc+4 后 MRET 返回）。新增指令占比约 5%，其余比例不变。

## 验收（Alan，同一最终 SHA）

- `scripts/lint.sh` PASS。
- O3-T01 全部现有门禁、O3-T02 固定程序（含 12 条复现）通过。
- ACT4：RV64I 51 项 0 差异，加上 ACT4 中 M 模式相关项（Zicsr、异常/ECALL/EBREAK 等，manifest 写进报告）0 差异。
- riscv-tests `rv64mi-p-*` 中适用于“无中断、无 S/U、无 PMP”的子集（至少 csr、mcsr、illegal、sbreak、scall、ma_addr 不适用则说明原因）通过，清单写进报告。
- Spike 随机种子 1–200 全部 0 差异（含 CSR/异常的新生成器）。
- 新增 cocotb：`rename_entry_gate`、`csr_file`、`trap_ctrl`/`commit_ctrl` 的定向与固定种子随机测试。
- 发现 DUT bug 时直接缩减、定位、修复并加入固定门禁，每个 bug 单独提交；只有需要改设计决策时才停。

## 不做

中断、S/U 模式、PMP/MMU、M/A/F/D/C 扩展、非对齐访存支持、完整 FENCE.I 数据侧序列。

## 回报

`doc/tasks/O3-T03-report.md`：提交号、命令与结果、每个修复的 bug（根因、修改、复现）、与本任务书的偏离、遗留问题。更新 `doc/LOOP.md` 与模块头注释。
