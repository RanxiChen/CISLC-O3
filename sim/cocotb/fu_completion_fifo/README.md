既有depth2定向用例保持不变，新增900周期seed105端口scoreboard检查固定payload槽碎片化、双结果、背压、kill/correct、pipeline释放、reset及提前通知。

重构完成后执行：

```sh
make SIM=verilator FIFO_DEPTH=2
make SIM=verilator FIFO_DEPTH=8 COCOTB_TEST_FILTER=stationary_payload_credit_conservation
```

目前仅编写，未执行功能仿真。执行前按共享主机配置重新预检。
