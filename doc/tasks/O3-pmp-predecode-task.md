# PMP 范围预解码（L1D PMP 时序修复）

2026-10-08 用户选定方案 A。依据：[L10 spec 9.1「范围预解码」](../spec/l10-priv-mmu-spec.md)、前端基线 D28 与第 8 节。触发证据：[O3-memory-ram-ooc-report](O3-memory-ram-ooc-report.md) L1D OOC，PMP 地址 → DCache 内部请求 `pmp_ok` 寄存器 −0.073 ns，30 级逻辑（Alan，100 MHz，综合后估计）。

## 给 Codex 的提示词

```text
任务：实现 L10 spec 9.1「范围预解码」，修复 L1D PMP→pmp_ok 的 setup 违例。以 spec 为准，不重开 PMP 语义。

开工前按 AGENTS.md 重新读取 /home/chen/leisure/flow/docs/cross-project/simulation-host.md：仿真先 cloud_chen，不可用则 Alan；Vivado 用 Alan。记录实际主机。

在当前分支 fix/memory-ram-ooc-20261008 上新开提交；工作区里已有的 doc/LOOP.md、O3-T10-report.md、O3-memory-ram-ooc-* 修改不属于本任务，不要混进本任务的提交。

改动：
1. o3_types_pkg：新增 pmp_dec_t {en; lo[56:0]; hi[56:0]; r,w,x,l}；pmp_state_t 增加 pmp_dec_t [PMP_N-1:0] dec（保留 update、entries）。
   新增 pmp_decode(entries) -> dec：无逐位循环，NAPOT 用 e^(e+1)（54 位回绕）求掩码；须与 pmp_lower/pmp_upper 逐值相等（含末尾 53/54 个 1、TOR 第 0 项 lo=0、OFF 项）。
   新增 pmp_allow_dec(dec, addr, bytes, priv, rd, wr, ex)：并行求每项 match/inside/perm，再按最小编号选择；无匹配时 M 允许、S/U 拒绝。
   dc_permissions 改为使用 dec。pmp_lower/pmp_upper/pmp_allow 保留为参考模型。
2. csr_file：pmp_dec_q 与 pmp_q 在同一沿更新，值为 pmp_decode(pmp_next)；复位与 pmp_q=0 一致。pmp_o 输出 dec。
   加仿真断言（`ifndef SYNTHESIS`）：pmp_dec_q == pmp_decode_ref(pmp_q)，ref 由旧 pmp_lower/upper 组成。
   周期 N+1 生效的合同不变。
3. 检查点改成 pmp_allow_dec（只读 dec）：icache.sv:124、ptw.sv:38/39、load_store_unit.sv:131（经 dc_permissions）、dcache.sv:201 和 :634 断言（经 dc_permissions）。
   frontend.sv:366 转发 dec。pmp_checker.sv 也改为读 dec，其 cocotb tb 同步驱动 dec（或在 tb 顶层调用 pmp_decode）。
   改完后 grep：rtl 中可综合代码除 csr_file 的参考断言外，不得再调用 pmp_lower/pmp_upper/pmp_allow。
4. 不改 PMP 语义、CSR 读写/锁定规则、流水级数、接口握手节拍、容量、黄金值与既有测试规模。

验证（每项记录主机、准确 SHA、命令、exit、用时）：
- lint：0 errors，warnings 数不得比 357 多；如有新增，逐条说明。
- 新增定向测试：pmp_decode 对照参考模型，覆盖 16 项 × {OFF,TOR,NAPOT}、NAPOT 末尾 1 个数 0..54 全扫、TOR 相邻项、L 位、随机 ≥10k 组（固定种子 1/7/29）；
  另对 pmp_allow_dec 与 pmp_allow 做随机地址/字节数/权限/特权对照。
- 既有：pmp_checker、csr_file、icache 三种子、frontend_sync_ctrl、dcache MSHR4/MSHR1 全套、mmu。
- 整核 MEM_PIPES=2 build + 13 项、MEM_PIPES=1 build + 12 项，全部 exit0，priv/VM 的周期数和退休数如有变化须解释（预期不变）。
- Alan L1D OOC（沿用 42968c2 的脚本、约束与无 retiming 配置）：报告原失败端点的 WNS、逻辑级数和数据路径延迟，以及全模块 WNS/TNS 与 LUT/FF 增量。
  目标是 setup ≥ 0。若仍 < 0，报告最差的 5 条路径后停下，不要自行加 pipeline、multicycle 或 false path。
  hold 边界违例不在本任务范围内，照实记录即可。

结果写入 doc/tasks/O3-pmp-predecode-report.md。只有执行过的项目才能写"通过"；综合估计不能写成布局布线或 FPGA 证据。
```

## 验收要点（Claude 复核用）

- 等价性：CSR 侧仿真断言 + 解码全扫 + allow 随机对照，三者都要通过。
- 时序：原端点 setup ≥ 0，逻辑级数明显低于 30。
- 不改合同：派生状态仍在 N+1 生效；整核 priv/VM 周期数不变。
