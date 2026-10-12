固定种子1000周期，完整opaque uop载荷、两个mask、两槽满缓冲不借同拍释放、独立取消/消费/入队、连续流、复位/flush。
原fu_issue_pipeline测试保留。后端重构期间尚未执行功能仿真。
按共享simulation-host.md选主机后：`make -C sim/cocotb/fu_buffer_storage TEST_SEED=105`。
