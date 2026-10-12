# L9 基本 FU 功能

执行前重新读取 `/home/chen/leisure/flow/docs/cross-project/simulation-host.md`，
先校验 cloud_chen，不可用再使用 Alan。在所选主机执行
`make -C sim/cocotb/fpu_fu TEST_SEED=1`。
固定 CVFPU/common_cells 依赖按父仓库 gitlink 初始化。

原有两个测试覆盖四个 split opgroup 的基本 D 运算、S 位搬运/boxing、转换、
NV/DZ、请求身份、结果背压保持、分支取消和全局 flush 后迟到结果丢弃及身份复用。
另有固定种子 32 组整数值的浮点加法，期望值由 Python 精确整数和 IEEE 位模式生成。
2026-10-11 新增两个 FMA 测试，**尚未编译或运行**：

- FP32/FP64 各连续五拍接受请求，WB 保持阻塞；按 ROB 身份核对结果和 flags。
- RNE/RUP 半 ULP 舍入、最小次正规数乘半导致 UF/NX、融合乘加一次舍入的抵消结果；
  固定种子 32 组 S/D 混合的精确整数值运算与舍入模式，随机输出背压和稳定性。
- 多级流水同时占用时，正确分支解析、选择性取消、全局 flush、复位及排空后身份复用。

当前采用 Breeze CVFPU `23153ba10a0ab8c6ee774b5e1a928007c3b2adcc`，
ADDMUL 为 FP32 5 级、FP64 7 级；不包含后端 RegRead 与包装结果保持槽。
不覆盖完整 IEEE 边界、长期持续吞吐、双 FMA 同拍、整个后端的所有取消交错，
也不证明 FP 提前唤醒（该接口本次未接入）。

整核入口 `make -C sim/o3 run-l9-fp` 验证译码到退休的基本功能，
失败 tohost 为 `2*阶段+1`（阶段 1～8），成功为 1。
程序含 F/D 运算、转换、访存、四条 FP RVC、flags、动态舍入、FS Off trap
和 50 次依赖/分支循环；不使用 MRET，不调用 Spike。
这是基本功能门禁，不替代 L9 spec 全部验收项或后续 SoC 回归。

`run-l9-fp-smoke` 是较小的顺序功能门禁，访存块间用 CSR 串行边界排空更老操作。
`run-l9-fp` 保留未串行化的依赖/replay 用例；已发现单槽 replay 可能阻塞更老 load，
构成 load→store→年轻 load 的等待环，不能用 smoke PASS 代替它的结果。
