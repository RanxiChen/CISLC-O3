# rename_entry_gate L5 合同

定向边界、复位、TEST_SEED 固定随机事务；包装只展开 struct，不修改状态。
Alan: `make -C sim/cocotb/rename_entry_gate SIM=verilator TEST_SEED=1`。
不覆盖本级未实现的中断、S/U、FP 或 L8 完整 FENCE.I。
