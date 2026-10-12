# uop_queue L3 contract

Run on Alan: `make -C sim/cocotb/uop_queue SIM=verilator TEST_SEED=1`.

Wrapper preserves all DUT ports and only exports configuration and state observations. Tests cover reset, directed four-wide/C/M boundaries and seeded DUT transactions. Target t_* ports remain outside the L3 contract. No full ISA, PPA or FPGA claim.

2026-10-11：默认三宽/深度8，测试从公开cfg读取容量，旧900周期seed与 FIFO golden 保留，定向填满允许尾批小于宽度。默认make包含已有1200周期完整packed-payload模型，覆盖新的固定writer/reader RAM及writer tag复用/flush。新增布局尚未执行功能仿真。
