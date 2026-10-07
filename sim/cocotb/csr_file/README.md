# csr_file L5 / L9 基本合同

定向边界、复位、TEST_SEED 固定随机事务；包装只展开 struct，不修改状态。
Alan: `make -C sim/cocotb/csr_file SIM=verilator TEST_SEED=1`。
L9 增加 FS/frm/fflags 复位、FS Off 非法访问、fcsr 别名、保留 frm 照存、
读不置 Dirty、软件写与退休 flags/Dirty、SD，以及 FS 变化保留 fcsr。
既有随机 WARL 参考模型按已实现的 F/D misa、FS/SD 合同更新。
不覆盖本级未实现的中断、S/U 或 L8 完整 FENCE.I。
