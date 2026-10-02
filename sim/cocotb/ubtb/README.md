# uBTB 单模块 cocotb

这里只检验 `ubtb` 的公开端口与首版周期合同，不启动尚未完成的 BPU/整核。
`ubtb_tb_top.sv` 只展开 packed struct 以便 cocotb 驱动，DUT 接口不变；
`ubtb_model.py` 使用配置输出建立独立参考模型，不在测试里写死 16 项或 16B。

在 Alan 的 Python 3.12 / cocotb 2.1.0 / Verilator 5.050 隔离环境运行：

```sh
make -C sim/cocotb/ubtb SIM=verilator TEST_SEED=1
make -C sim/cocotb/ubtb SIM=verilator TEST_SEED=0xC15C WAVES=1
```

第二条使用独立的 VCD 构建目录。`results.xml`、`dump.vcd`、`sim_build/`
都是生成物，不提交。`requirements.txt` 固定 Python 依赖，系统 Verilator
不在仓库安装。

每周期先检查边沿前的组合预测，再提交训练并检查边沿后的预测。与有注册
读口的 `main_btb` 不同，uBTB 同拍查询/训练在边沿前读旧表、边沿后读新表。
定向测试覆盖顺序 miss、入口槽过滤、方向计数、JAL/JALR、stall 与训练独立、
空项优先/满表替换、部分 tag 别名、reset；另有 600 周期固定种子随机事务。
失败断言包含种子、周期、阶段和输入，可按 `TEST_SEED` 重放。

单模块 PASS 不代表 BPU/FTQ 集成、预测命中率、综合资源或 FPGA 时序通过。
