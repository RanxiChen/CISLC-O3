# hpm_counters L7a 合同（spec 6.3、U11、U21）

期望值按 spec 推算，不读 RTL 内部状态；每个行为一个定向用例。
包装只展开 struct 与 perf 打包向量，不加状态。
运行：`make -C sim/cocotb/hpm_counters SIM=verilator TEST_SEED=1`。
不覆盖 S/U 访问、mcounteren、Sscofpmf（L10）。
