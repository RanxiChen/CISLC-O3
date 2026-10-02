# TAGE 单模块 cocotb

本目录只检查 `tage` 公开端口的三阶段查询与提交训练，不启动尚未接通的
BPU/FTQ。`tage_tb_top.sv` 展开 packed struct，DUT 接口与 `O3_CFG` 不变；
Python 模型从包装顶层读取容量和位宽，保留独立的表及 S1/S2 快照。

在 Alan 的 Python 3.12、cocotb 2.1.0、Verilator 5.050 环境运行：

```sh
make -C sim/cocotb/tage SIM=verilator TEST_SEED=1
make -C sim/cocotb/tage SIM=verilator TEST_SEED=0xC15C WAVES=1
```

第二条启用 VCD 并使用独立构建目录。`sim_build/`、`results.xml`、
`dump.vcd` 不提交。`requirements.txt` 固定 Python 依赖。

每周期在边沿前、后都核对 valid/ready；有效 S2 响应比较全部方向位、
provider 命中位和 metadata。定向测试覆盖 base 初态、原历史训练、
tagged provider、折叠历史区分、同拍读旧值、stall 保持、kill 清除和
多槽同包训练；另用 900 周期可复现随机事务检查流水与陈旧训练上下文。
单模块 PASS 不代表 BPU/FTQ 集成、方向准确率、综合资源或 FPGA 时序通过。
