# LSU L5

独立 load/store 访问错误、自然对齐只读 store 探测、trap 迟到响应与回压。
原 L3 suite 不变，本 suite 启用实际 backend 的 CHECK_STORE_ACCESS=1。
Alan：make -C sim/cocotb/load_store_unit_l5 TEST_SEED=1。
