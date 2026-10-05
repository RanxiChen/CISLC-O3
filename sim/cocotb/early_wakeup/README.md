# L6 early_wakeup 定向验证

Alan：`make -C sim/cocotb/early_wakeup`。

只测试接口、身份、取消、握手和少量典型/边界运算。不运行随机算术或新增 Spike 随机门禁。
测试中 wake 必须指向下一拍可见的 FIFO 头；背压期间的结果持续可见。
