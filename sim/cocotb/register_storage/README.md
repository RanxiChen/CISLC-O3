# Physical register storage

Independent INT/FP scoreboards initialise storage through writes, then check all
read replicas, same-cycle bypass, INT p0 and writable FP p0, duplicate-write priority,
and allocation/write precedence in readiness. 700 fixed-seed cycles retain old
ready bits until the edge. FPGA RAM data is not required to reset to zero.

Function execution is deferred until backend refactoring completes. Before compile
or simulation reread the shared simulation-host.md and preflight cloud_chen, then
Alan on failure. Run make here with PRF_FPGA=1 (production) or PRF_FPGA=0 (generic).
No whole-core or FPGA proof follows from this module test.

补充三写银行候选复验（后端重构后执行）：

```sh
make SIM=verilator PRF_FPGA=1 INT_READS=6 INT_WRITES=3
```

同一700周期seed105 scoreboard按公开维度检查所有读副本、同址多写优先和旁路；默认仍为当前INT4R2W。
