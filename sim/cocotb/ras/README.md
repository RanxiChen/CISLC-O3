# RAS 单模块 cocotb

在 Alan 的独立 GitHub checkout，使用 Python 3.12、cocotb 2.1.0 和 Verilator 5.050：

```sh
make -C sim/cocotb/ras SIM=verilator TEST_DEPTH=16 TEST_SEED=1
make -C sim/cocotb/ras SIM=verilator TEST_DEPTH=3 TEST_SEED=0xC15C
make -C sim/cocotb/ras SIM=verilator TEST_DEPTH=1 TEST_SEED=0x29
```

包装顶层只展开 `ras_ckpt_t`、恢复身份和性能事件，并把深度设为 16、非 2 次幂
的 3 或同址双写的 1；DUT 接口保持不变。Python 模型独立维护数组、栈顶索引与
占用数。每次操作在上升沿前核对旧栈顶、入口检查点、完成身份和事件；上升沿后
核对新状态，并在输入仍保持时重新核对当拍事件。

定向事务覆盖空栈 pop/pop-push、满栈覆盖、环绕、恢复修复、恢复与普通操作冲突、
正确 pop-push、恢复请求在边沿前替换、深层污染和深度 1 的同址写优先级。
每个种子另执行 800 周期随机操作与历史检查点恢复。`sim_build/`、`results.xml`
和波形文件均不提交。单模块 PASS 不代表 BPU/FTQ 集成、真实 return 预测率、
综合资源或 FPGA 时序通过。
