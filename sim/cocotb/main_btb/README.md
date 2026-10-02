# main_btb 单模块 cocotb

这里只测试 `main_btb` 的公开端口和周期合同，不启动尚未完成的 BPU/整核。
`main_btb_tb_top.sv` 仅把跨语言不便驱动的 packed struct 展成普通端口，
并把未被该模块使用的训练上下文清零；DUT 接口和 RTL 不因测试改变。

在 Alan 上使用 Python 3.12、cocotb 2.1.0、Verilator 5.050 的隔离环境：

```sh
make -C sim/cocotb/main_btb SIM=verilator TEST_SEED=1
make -C sim/cocotb/main_btb SIM=verilator TEST_SEED=1 WAVES=1
```

第二条使用独立的带 FST 跟踪的构建目录；结果为本目录的 `results.xml`，
可选波形 `dump.fst`，编译产物在 `sim_build/`，均不提交。
`requirements.txt` 固定 Python 依赖；系统 Verilator 不在仓库内安装。

测试每周期先在低电平设置输入，等组合逻辑稳定后检查旧响应（stall/kill
在此刻就必须生效），再给上升沿并检查新响应。参考模型先锁存训练前的表项，
随后更新训练表；因此同拍查询/训练应读旧值。`resp_o` 只在
`resp_valid_o=1` 时比较，因为 stall 下 DUT 可以保留无效的旧数据。
失败消息包含种子、周期、阶段和输入，固定 `TEST_SEED` 即可重放。

当前验证不证明预测率、BPU/FTQ 集成、综合或 FPGA 时序。`sim/o3` 的整核
C++ 仿真入口独立保留，不因本目录改变。
