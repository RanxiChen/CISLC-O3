# O3 T12c — FDIP 预取与特性 CSR

源码 SHA `a873a48a48118c0d0e2447cc006f1d907f4abb58`。FTQ 预取游标按 slow_done/demand 未发门控，次态追赶 demand；FTQ 自身保留候选直至握手，不额外复制请求队列。预取实现连续同行去重、Bare 高位校验、4 项 Sv39 翻译复用（含超级页、G/ASID/epoch）、空闲 ITLB 口命中探测。探测不分配 miss、PTW、故障槽或更新 PLRU，也不计 demand ITLB 事件。共享 SFENCE 范围谓词供 ITLB 与复用记录使用。取消/hold 丢弃迟到探测。

ICache 新预取分配保留一个空 MSHR 给 demand；分配前检查 64B PMP X、PMA 与 epoch。MSHR pf_only 在 demand 合并时清除并计一次 late；回填来源传入 tag，首次 demand 命中计 useful，未使用来源行被替换计 unused。CSR `mo3fecfg` 0x7c0 仅 M 访问，bit0 LOOP_DIS、bit1 PF_DIS，高位读零写忽略、无 refetch。通过独立 retired HPM 聚合检查保留原有事件断言。

cloud_chen，Verilator 5.050，cwd `/home/cloud_chen/work/l7c-t12c`。证据 `/home/cloud_chen/evidence/o3-l7c/t12c`：`unit2` 为提交前快照，`ftq-lint` 为后续额外游标用例与组合依赖整理，`core-gate` 为上述 SHA，命令/退出码/日志均保留。

- prefetch/reuse 3/3；ICache 6/6；CSR 12/12；MMU 8/8（含连续 32 页 miss 探测无 PTW 和 resident hit）；FTQ 4/4。
- 原 4 个 ICache 用例和 7 个 MMU 用例保持；新增权限/epoch/PMA、3 个 PF MSHR 保留、实际数据/useful/late/unused、demand 优先探测、四种 SFENCE、超级页/epoch、取消/disable 等用例。
- lint 最终 0 errors、357 warnings（将 fill 来源输出与 ready 组合块拆开，消除额外组合环警告）。
- 13 个整核回归目标 exit 0：predict A/B 24217/24207 cycles；L8a mem 96345/62786、golden 前缀通过；priv 3795/437、VM 11526/6435；AMO 41330/7803、MMIO 3808/1245、misalign 12553/7048、DMA 13248/3347。

第 14.2 节冷流 A/B 被纳入 T12d 最终程序与同 SHA 门禁；本报告不以定向用例代替收益测量或物理时序证据。

## 自行决定

- 候选保存在 FTQ，不再复制预取请求队列；用完整 id、页表 epoch 与对齐虚拟行确认迟到探测身份。连续同行去重在 kill/SFENCE/epoch 变化时失效。涉及 `fetch_prefetcher.sv`、`ftq.sv`。
- ITLB 探测响应与 demand 响应显式隔离；复用记录采用共享 SFENCE 范围谓词，保留超级页与 G/ASID 匹配。涉及 `itlb.sv`、`prefetch_xlate_cache.sv`、`o3_types_pkg.sv`。
- 预取坏权限/过期请求无需等待 MSHR 空位即可消费，合法请求仍严格保留一个 demand MSHR；PF 来源随填充进入 tag，事件由独立整核监视器核对。涉及 `icache.sv`、`icache_mshr.sv`、`l7_event_checks.sv`。
