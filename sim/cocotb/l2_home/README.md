# L8a M1

Run on the simulation host selected by `docs/cross-project/simulation-host.md`
in the Flow repository, after rereading the configuration and preflight.

- `make`: pressure geometry (2 sets, 2 ways, 2 slots), ten directed cases and
  seeds 51/52. Each seed completes at least 2000 accepted L1D GetS/GetM/Put
  transactions plus 500 concurrent L1I Reads, then reads back all written lines.
- `make SETS=4 WAYS=2 SLOTS=2 COCOTB_TESTCASE=slot_full_backpressure_and_resume`:
  fills both slots and holds a third different-set REQ stable until a release.
  This auxiliary geometry makes slot-full observable without violating credits.
- `make SETS=512 WAYS=8 SLOTS=8`: the ten directed cases at default L2 geometry.

The behavioral L1D retains clean/dirty copies, silently stores only with E/M
permission, sends every eviction as Put, and answers probes independently of
REQ readiness. The AXI RAM permits AW/W independence, interleaved read IDs,
random ready/latency and delayed B. The architectural golden memory is separate
from AXI backing RAM. Reads concurrent with stores must equal a value that
existed during their interval. Final readback is exact. Permission monitoring
uses only link handshakes; directory structural checks run every cycle and
exact correspondence is checked after quiescence. DMA is tied off.

后端重构新增`client_payload_fifo_reuse_with_response_backpressure`：seed105、40批四条L1I完整返回与独立DMA一槽，验证held身份/512-bit数据、部分消费、wrap/复用。Bench新增可选每client ready控制，旧默认ready/随机种子/事务规模保留。新载荷存储与测试尚未功能执行。
