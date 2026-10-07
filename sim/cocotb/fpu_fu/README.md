# L9 基本 FU 功能

在 Alan 的 `cislc-o3` 环境执行 `make -C sim/cocotb/fpu_fu TEST_SEED=1`。
固定 CVFPU/common_cells 依赖按父仓库 gitlink 初始化。

两个测试覆盖四个 split opgroup 的基本 D 运算、S 位搬运/boxing、转换、
NV/DZ、请求身份、结果背压保持、分支取消和全局 flush 后迟到结果丢弃及身份复用。
另有固定种子 32 组整数值的浮点加法，期望值由 Python 精确整数和 IEEE 位模式生成。
不覆盖完整 IEEE 边界、持续吞吐、双 FMA 同拍、整个后端的所有取消交错。

整核入口 `make -C sim/o3 run-l9-fp` 验证译码到退休的基本功能，
失败 tohost 为 `2*阶段+1`（阶段 1～8），成功为 1。
程序含 F/D 运算、转换、访存、四条 FP RVC、flags、动态舍入、FS Off trap
和 50 次依赖/分支循环；不使用 MRET，不调用 Spike。
这是基本功能门禁，不替代 L9 spec 全部验收项或后续 SoC 回归。

`run-l9-fp-smoke` 是较小的顺序功能门禁，访存块间用 CSR 串行边界排空更老操作。
`run-l9-fp` 保留未串行化的依赖/replay 用例；已发现单槽 replay 可能阻塞更老 load，
构成 load→store→年轻 load 的等待环，不能用 smoke PASS 代替它的结果。
