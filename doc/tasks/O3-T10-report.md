# O3-T10 L8b 实施报告（进行中）

## 当前状态与证据边界

- 分支：`feat/L1-closure`；预读与审计起点：`3e52d60c48cafebb2ed4b3b93fd8c734aca8f284`。
- 冻结依据：`doc/spec/l8b-atomic-mmio-dma-spec.md`、`doc/spec/l8a-nonblocking-mem-spec.md`；顺序与停止条件：`doc/tasks/O3-T10-l8b-tasks.md`。
- 指定旧行为的静态依赖审计与指定预读已完成；第 1 步 RTL 实施开始。
- 第 1 步完整 RTL 与用户批准的测试迁移已应用，第 04 轮静态门禁全部通过；本报告随首次 RTL 提交保存，完整 SHA 记录在外部 rtl-delivery.json 及对应 git log 提交。尚未运行功能仿真或进入 N1～N6，不声明功能门禁通过。

## 用户批准的测试迁移

用户于本次任务中批准三处 MISA 黄金值从 `0x800000000014112c` 改为 `0x800000000014112d`：

| 文件及起点行号 | 改动 |
| --- | --- |
| `sim/cocotb/csr_file/test_csr_file.py:44` | 初始参考状态的 MISA 常量置 A 位 |
| `sim/cocotb/csr_file/test_csr_file.py:56` | WARL 写入参考值的 MISA 常量置 A 位 |
| `sim/o3/tests/l9_fp.S:20` | 整核自查的 MISA 常量置 A 位 |

理由：冻结 L8b spec 第 3 节要求 `misa.A=1`；这些是 L9 时期写死的旧常量。只改常量，其余断言、400 次随机访问和种子规则保留。三处测试修改与 `rtl/system/csr_file.sv:80` 的 RTL MISA 修改放在同一个 RTL 提交中，避免出现 RTL 与测试不一致的中间状态。当前三处常量迁移已应用，将与对应 RTL 同提交。

## 旧行为全量审计（起点 SHA）

审计范围：`rg --files rtl sim verification` 列出的 451 个仓库文件；与 `git ls-files rtl sim verification` 的 500 个 tracked 文件和 `rg --files -uu` 的 1334 个本地文件交叉核对。默认检索遗漏的 tracked 文件仅为 49 个 `.gitignore`；额外本地产物为旧生成 C++/编译文件、缓存、XML 与 trace，不作为可迁移源码或当前 SHA 证据。检索 MISA（包括数值、CSR 地址）、`clean_all` 及 wrapper 的 `clean_req/clean_ack`、`crossline_misalign`、`BE_MISALIGNED_CROSSLINE_TRAP`、`'h24`（含数值候选），以及非法编码、异常原因和 IO 地址候选。补充静态检查全部 14 个 `.hex` 的 32 位字低 7 位是否为 `0x2f`，并核对生成器、模型和测试上下文。未执行这些程序。

### 用户批准的测试迁移 A：FENCE.I 删除旧握手

依据：L8b 第 9 节及 12.1 节删除 `clean_all_*`；流程仍是 committed SQ 排空、前端同步、退休重取。

| 文件及起点行号 | 旧依赖 | 建议改法 |
| --- | --- | --- |
| `sim/cocotb/commit_ctrl/test_commit_ctrl.py:110,113,115,116` | 用例名称及断言要求 clean req/下一拍 ack | 更名为等待 SQ 与前端同步的用例；12 拍 SQ 非空检查保留，旧 clean 断言替换为同步前不能完成、同步握手及完成确认；保留退休 redirect/flush 检查 |
| `sim/cocotb/commit_ctrl/commit_ctrl_tb_top.sv:2,18,19,38` | 导出旧请求/应答并生成兼容 ack | 删除这两个端口、ack 寄存逻辑及 DUT 的三个 clean 连接 |
| `sim/cocotb/dcache/dcache_tb_top.sv:16` | DUT wildcard 连接的旧端口 | 删除三个 clean 端口，保留其余驱动/观测 |
| `sim/cocotb/mmu/pte_cache_tb_top.sv:16` | DUT wildcard 连接的旧端口 | 同上 |
| `sim/cocotb/memsys/memsys_tb_top.sv:18` | 传给 dcache wrapper 的旧端口 | 同上 |
| `sim/cocotb/dcache/l8a_agents.py:107` | reset 名单中的旧输入 | 仅删除 `clean_all_req_i` 名称 |
| `sim/cocotb/memsys/system_agents.py:40` | reset 名单中的旧输入 | 同上 |

批准并应用的替换用例：

```python
async def fence_i_waits_for_sq_and_frontend_sync(d):
    await reset_l10(d)
    d.head_valid_i.value=1; d.head_serial_i.value=1; d.sysop_i.value=7
    for _ in range(12):
        await edge(d)
        assert not int(d.sync_o.value)
        assert not int(d.serial_done_o.value)
    d.sq_empty_i.value=1
    await settle()
    assert not int(d.serial_done_o.value)
    d.sync_ready_i.value=1
    await settle()
    assert int(d.sync_o.value)
    await edge(d)
    assert not int(d.serial_done_o.value)
    d.sync_done_i.value=1
    await edge(d)
    d.sync_done_i.value=0
    assert int(d.serial_done_o.value)
    d.commit_valid_i.value=1
    await settle()
    assert int(d.redirect_o.value) and int(d.flush_o.value)
```

### 用户批准的测试迁移 B：PMA 的原 DTCM 地址现在属于 IO

依据：L8b 第 6.1 节，`[0x02000000,0x80000000)` 为存在、可读写、不可缓存、不可执行的 IO 区。

`sim/cocotb/pmp_checker/test_pmp_checker.py:43-46,52-54` 的旧参考模型只允许主存，并要求原 DTCM 地址 `0x11000000` 附近的每种访问全部拒绝。建议保留原边界探针及 200 次随机探针、地址、size、种子，参考区间增加 IO，分别建模 cacheable 与 executable 属性；仍检查访问的完整字节范围，跨区域边界不能合并授权。

批准并应用的核心替换：

```python
# (lo, hi, cacheable, executable)
mapped_ranges=[(0x02000000,0x80000000,False,False),
               (0x80000000,0x100000000,True,True)]
permitted=[x for x in mapped_ranges if x[0]<=addr and addr+size<=x[1]]
exists=bool(permitted)
cached=exists and permitted[0][2]
executable=exists and permitted[0][3]
# 原五属性断言的预期值改为：
# (exists,cached,executable,exists,exists)
```

### RTL 中已由 spec 授权的修改

| 文件及起点行号 | 建议改法与冻结条目 |
| --- | --- |
| `rtl/system/csr_file.sv:80,132,181` | 修改唯一 MISA 常量，读/WARL 写路径自动沿用；第 3 节 |
| `rtl/system/commit_ctrl.sv:24,45,93-95,216` | 删除 clean 端口/请求逻辑，更新流程注释，事件按退休握手计数；第 9/11 节 |
| `rtl/backend/backend.sv:246,2153,2210` | 删除 clean 连线与声明；第 9 节 |
| `rtl/lsu/dcache.sv:21,367,369,484` | 删除 clean 端口、下一拍 ack 和恒零 busy；第 9 节 |
| `rtl/lsu/dcache.sv:262-264` | 原跨行异常路径由 HEU 拆分替代；保留调试关闭与原子/IO 自然对齐异常；第 2/5/6/7 节 |
| `rtl/common/o3_types_pkg.sv:1163,1172,1224`、`rtl/backend/rob.sv:18` | 删除旧 crossline 字段及对应注释；第 9/12.1 节 |
| `rtl/common/o3_types_pkg.sv:1269` | BE 的 `'h24` 更名为 `BE_MISALIGNED_CROSSLINE_SPLIT`，编码保持；只计成功退休；第 7/11 节 |
| `rtl/common/o3_types_pkg.sv:1080-1091`、`rtl/lsu/lrsc_reservation.sv` | 旧 reservation 空壳/注释改为 Y3 清除表与寄存态判定；第 5.3 节 |
| `rtl/backend/decoder.sv`、`rtl/backend/backend.sv:1551`、`rtl/backend/writeback_arbiter.sv:8,22` | opcode 0x2F 增加合法 RV64A 译码并接 HEU 写回，更新未实施说明；第 3/4 节 |
| `rtl/common/pma_checker.sv`、`rtl/common/o3_cfg_pkg.sv:43-45` | 增加 IO 区、区间属性与权限寄存所需位；第 6 节 |

`rtl/system/backend_perf_events.sv:12-13` 留有旧跨行 trap/evict 口径注释，但该文件是未实例化的空壳、未列入 L8b allowlist；本任务不修改，报告记录其说明过时。

### 检索命中但不需要迁移的现有测试

- `sim/cocotb/icache/test_icache.py:277-285` 的 `0x11000000` 取指 access fault 仍正确：IO 不可执行；只需未来维护时改 DTCM 说明，不改期望值。
- `sim/cocotb/mmu/test_mmu.py:63-66` 的 Bare 地址翻译 identity hit 仍正确：只测 TLB 翻译，不授权 IO 取指。
- `sim/cocotb/dcache/test_l8a_dcache.py:155-160` 的 `VA=0x12345678` 是故障 tval；实际 PA 越过 32 位，cause 5 仍正确。
- `sim/cocotb/decoder/test_decoder.py:18` 是 `SFENCE.VMA rd!=x0` 非法编码，不是 AMO；保留。
- `sim/o3/tests/gen_mmode.py:16` 与 `sim/o3/tests/mmode.hex:16` 读取 MISA，没有旧 MISA 常量自查；无需补丁。
- 全部 14 个 `.hex` 的扫描未发现低 7 位为 0x2F 的 32 位字；测试/生成器中未发现以合法 AMO 编码预期非法的现有用例。`0x0000000b` 等非法 opcode 仍非法。
- `rtl/common/o3_types_pkg.sv:695` 的 FE `PE_ICACHE_MSHR_MERGE='h24` 属于前端事件空间，保持不变；`.expected.json` 中数值 0x24 是寄存器结果，不是 BE 事件选择。
- `verification/act4/config/*/rvmodel_macros.h:28` 的 access-fault 地址为 0，仍处于不存在区，保留。
- IO 地址检索中的 PTE 常量、PMP 边界值、整数/FP 数据、系统指令字及前端队列的纯 PC 标签经上下文核对，不是新增 IO 的错误授权期望。

### 本任务之外的旧验证配置（只审计、不修改、不运行）

两个 ACT4 目标是历史 L5/RV64I 配置，并非 L8b 验证目标，且 `verification/` 不在 spec 第 0 节允许修改范围。下列配置不能作为当前 L8b 合同或证明，本任务建议保持原样并记录差异：

| 文件及起点行号 | 差异与未来建议 |
| --- | --- |
| `verification/act4/config/cislc-o3-l5/cislc-o3-l5.yaml:8-13,38-39` | ISA 列表无 A；普通非对齐设为异常。未来新建 L8b 专用目标时加入实施 ISA 并按 B49 设置普通非对齐支持/异常优先级，保留历史目标 |
| `verification/act4/config/cislc-o3-rv64i/cislc-o3-rv64i.yaml:8-10,35-36` | 同类历史 ISA/非对齐差异，处理同上 |
| 两目标 `sail.json:207-208,218-224` | 全局普通非对齐设 AlignmentException，原子/LRSC 设 AccessFault。未来专用目标按主存普通拆分、原子自然对齐 cause 4/6 配置；先核实 Sail 是否可表达全部精确异常口径 |
| 两目标 `sail.json:302-306,317-319` | IO 区大小为 0x0e000000，IO 区局部普通非对齐允许。未来专用目标扩为 0x7e000000 并在 IO PMA 拒绝非自然对齐 |
| 两目标 `sail.json:383-399` | reservation 模型与 O3 同地址同大小、Inv/逐出清除表需重新评估；未来专用模型验证，不冒称参数替换足以覆盖 |
| `sim/o3/spike_lockstep.h:61` | Spike 固定 ISA 为 rv64im_zicsr_zifencei_zicntr，缺 A，且已有其他旧 ISA/特权差异；本任务按禁止 Spike 的要求不改不运行，未来独立升级 |

### 审批与继续执行

用户批准 MISA 三处，以及迁移 A 的七个文件、迁移 B 的 PMA 黄金模型与 wrapper；全部与对应 RTL 放在同一个第 1 步提交中。A/B 均记为“用户批准的测试迁移”。原有边界、断言、规模和种子全部保留。B 额外增加 IO 下边界 0x02000000 的边界/随机探针、0x7fffffff 附近跨区拒绝，以及 io/amo_ok/rsrv_ok 三个输出的独立检查：IO=(1,0,0)，主存=(0,1,1)，不存在=(0,0,0)。额外随机探针在原探针生成之后追加，保留原随机序列。

### 预读来源

冻结 L8a/L8b spec 与 T10 任务书完整读取；L8b 第 1 节列出的现有源码位置已核对。Breeze 指定 spec、源码、四份 memsys 测试和单核原子报告均从 a304cc2ac718f2b11dc631ec1218774fc4c90748 读取。SOC-2-bram-report.md / SOC-3-timing.md 在该提交不存在，读取任务书引用的当前文档；其最近文档提交 ae343c2027cc1e59f8f15212157ea82fd2020e15。该时序材料仅用于理解 Y13/Y14 起因，不引入额外架构依据。

## 自行决定（实施中）

- HEU 复用 LSU 最后一个活动管道：mem_pipes=2 时管道 1，mem_pipes=1 时管道 0；内部 PTW/A-D 的优先级保持更高。
- HEU 增加无副作用的翻译/权限检查请求；拆分先检查完整两半范围，再执行读写，使用显式字节数表示非二次幂的半段。
- 权限字段放入 CPU S1 请求并在 cache S2 寄存；内部来源在发射时计算并寄存。Y13 shadow 重算与断言全部放在 ifndef SYNTHESIS 内。

- 新增 struct 字段导致旧 wrapper/代理位宽变化，只作接口编码适配，保留所有原有黄金值、断言及用例规模；cache 叶测试编译清单增加实际例化的 reservation 模块。
- MPRV/MPP/SUM/MXR 改变时复用 SYS_PMP 串行冲刷，既保证 Y13 上下文一致性，也避免把这些 CSR 写误当 satp 写清除 reservation。ITLB walker valid 与 ready 同时在 CSR/trap 上下文切换拍门控，防止已接受的前端请求被静默丢弃。
- 原子 RMW 判定排除已预约的下一拍整行槽，PS 下一拍必写；仿真专用断言校验两拍窗口。reservation 同拍多种冲突按已寄存 reservation 行做或，避免不同地址的事件覆盖需清除的同行事件。

## 第 1 步动态开发证据（尚未最终闭合）

实际主机 cloud_chen@47.96.71.231:22，hostname iZbp16rhtg91v96m32vggjZ；Verilator 5.050（2026-07-01），cocotb 2.1.0。环境激活 /home/cloud_chen/setup/activate-o3.sh；内存约 29 GiB 可用、磁盘约 26 GiB 可用，预检成功，无需 Alan。独立 cwd /home/cloud_chen/work/20261008-t10-3e52d60c；证据 /home/cloud_chen/evidence/20261008-t10-3e52d60c。开发快照 base SHA=3e52d60c48cafebb2ed4b3b93fd8c734aca8f284 + WIP 文件哈希清单，不冒充已提交 SHA。

- rtl-lint-01.log：exit 1，FP 仲裁 NUM_SRC 原为 localparam，新增 HEU FP 写回源不能覆盖；改为 parameter。
- rtl-lint-02.log：scripts/lint.sh exit 0，0 errors / 358 warnings；其后有 RTL 修正，须复验。
- rtl-elab-default-01.log：verilator --cc --assert -Wno-fatal -f rtl/rtl.f --top-module l8b_elaborate_top sim/o3/tests/l8b_elaborate_top.sv；exit 0。既有组合环警告与新增 CSR 路径警告仍在审阅，不作为功能证明。

- 开关矩阵第 03 轮在 22 个组合通过后主动中止（driver exit 130），静态审阅发现 backend 的 SQ 状态变化通知遗漏 HEU 完成事件，可能令年轻 load 无后续唤醒。新增 heu_complete 通知；LQ 的 DMA 顺序标记排除已有异常和正在被分支取消的项。此前结果只作开发证据，随后完整重跑全部 64 组合。

## Y13/Y14 权限寄存与上下文一致性（RTL 审阅，功能测试待分层执行）

CPU/HEU：load_store_unit.sv 的 translated_req 在 S1 从 DTLB 结果构造 PA，计算 dc_permission_t 的 pmp_ok/exists/io/amo_ok/rsrv_ok/high_addr；dcache.sv 在 s2_q.req 寄存并仅按这些位作权限、MMIO、原子判定。access_valid/read/write 保留原访问意图，避免年轻 STA 被 A/D 排序阻塞时 is_sta 清零导致 shadow 重算改变访问类型。S1 的 SQ 查询不以权限异常位门控；已有翻译 miss 仍不查询。

PTW/PTE A/D：dcache 的 internal_choose 在内部发射时以 S 特权、完整访问范围计算权限，随后 internal_launch_q/s1_q/s2_q 寄存。committed drain 的 pmp_ok 复用 STA 授权，shadow 排除 drain，沿用 T09 已批准合同。

一致性依据：commit_ctrl 的 CSR 执行等待 ptw_idle，PMP/satp/MPRV/MPP/SUM/MXR 写经 refetch 串行冲刷；trap/xRET 产生 flush。ptw 的 idle 是寄存状态 IDLE，包含 ITLB、DTLB 和内部 A 更新等待；backend 对 ITLB 请求 valid/ready 在 CSR/trap 拍同时门控，避免新 walker 与上下文变更同拍进入。普通非推测 D 更新位于更老 store/HEU 的 ROB 队头阶段，PMP CSR 不能越过它。

dcache.sv 的 Y13 一致性断言和 dc_permissions shadow 调用一起包在 ifndef SYNTHESIS 内：对有效、未被取消、已完成翻译且无既有异常的 CPU/内部请求，按 S2 当拍 pmp_i/current priv_i 重算，与寄存权限比较，差异 fatal。所有动态测试须使用 --assert；目前只有静态解析/代码生成，不声明上述一致性已获功能验证。

## 新发现的同类常量迁移：T09 截止前缀参考（用户已批准）

静态审计完整 T09 最终 SHA 6f0565fa8ce0a28655559aa116ae8c85c5d43786 的 15 份退休参考 JSONL，只有 l9_fp.jsonl 依赖旧 MISA 常量。它不在仓库中；本地证据文件 /tmp/t09-resume-evidence/6f0565fa/references/l9_fp.jsonl，远端冻结证据 /home/cloud_chen/evidence/t09/6f0565fa/references/l9_fp.jsonl。原文件 SHA256=7cae0bba9fb513868090ecee6cbc88b78a0ee64b537105fcd27d4e467b6aa365。

| 文件行号 | PC / 字段 | 旧值 | 建议迁移 |
| --- | --- | --- | --- |
| l9_fp.jsonl:7 | 0x80000014，misa 读的 rd_wdata | 0x800000000014112c | 0x800000000014112d |
| l9_fp.jsonl:12 | 0x80000028，构造黄金常量的 ADDI instruction | 0x12cf8f93 | 0x12df8f93 |
| l9_fp.jsonl:12 | 同条 ADDI 的 rd_wdata | 0x800000000014112c | 0x800000000014112d |

冻结 L8b 第 3 节要求 A=1；用户已批准 sim/o3/tests/l9_fp.S:20 常量变化。对应 ADDI 机器码必然改变，但 sim/o3/tests/compare_retire_traces.py:34-38 的严格 key 包含 instruction，所以原参考会在事件索引 10（order=10，0x80000028）发生确定的黄金冲突。该处是静态定位，尚未运行整核，不能写作已复现的动态失败。

建议只在 T10 证据目录创建参考副本，将上述两个原值字段及一个机器码字段准确迁移；先断言源 SHA/hash、PC、order、原值与唯一匹配条数，再写副本。T09 冻结原始证据不改；其余所有行、PC、顺序、异常、退休/截止/尾部条数保留。比较脚本完全不变，继续逐事件严格比较；最终报告同时记录原/迁移副本哈希及批准依据。生成工具可放在允许的 sim/o3/tests/ 下。迁移按批准方案应用；不使用 DUT 输出建立参考。

用户批准此项迁移，并补充授权：已批准源码/常量修改必然引起的机器码、写回值、同源 hex/参考 trace 可以直接迁移；须逐字段追溯、断言原值并在报告逐条记录。不能追溯的差异仍停止询问。此授权不改变任何比较断言或退休尾部规则。

## 第 1 步最终静态门禁

第 04 轮 WIP 内容哈希由 rtl-wip-04-manifest.json 固定，所有参与 RTL/测试源码在本地提交前逐文件校验完全一致。rtl-static-results-04.json 共 66 项：scripts/lint.sh、默认整核代码生成、全部 64 个六开关笛卡尔组合，每项 exit 0；最终 lint 为 0 errors / 359 warnings。每项开始前实时重读 simulation-host.md、预检 cloud_chen 成功；4 个独立开关检查并行执行，断言参数 --assert，未运行功能测试。预检原始输出保存在 preflight-logs.tar.gz；没有改用 Alan。

默认代码生成：verilator --cc --assert -Wno-fatal -f rtl/rtl.f --top-module l8b_elaborate_top sim/o3/tests/l8b_elaborate_top.sv --Mdir <evidence>/elab-default-04；exit 0。

64 组合：verilator --lint-only --assert -Wno-fatal -f rtl/rtl.f --top-module l8b_elaborate_top sim/o3/tests/l8b_elaborate_top.sv -GHEU=<0/1> -GSPLIT=<0/1> -GORDER_FLUSH=<0/1> -GRFO=<0/1> -GMEM_PIPES=<1/2> -GMSHRS=<1/4>；全部 exit 0。该前端解析完整展开参数与实例，默认项另执行 C++ 代码生成。工具告警原样保留；不宣称 0 warnings 或功能正确。

动态功能用例数、退休数、周期数均 N/A；N1～N6 和 run-l10-vm 动态复现尚未开始。未改 spec/design/LOOP，未推送 origin。退休参考常量审批已收到，继续 N1。

## 用户批准的测试迁移：退休参考已执行

首次 RTL 提交：dc261d24c858e25a314513d53994d34bb827c646。生成器 sim/o3/tests/migrate_t10_misa_reference.py 校验源 SHA256、PC、order、原值、唯一匹配条数后，只替换批准的 3 个字段；其余行逐字节不变。T09 原始证据再次校验不变。

原文件 SHA256=7cae0bba9fb513868090ecee6cbc88b78a0ee64b537105fcd27d4e467b6aa365；T10 副本 SHA256=9c88fb8b707acc3d24e5933d123d5ad3d87262547c935b43c0b6584ae17800c0；两者均 616 行。字段清单见上表及副本旁的 migration.json。远端每个准确 SHA 的 T10 证据目录使用同一生成器建立副本，比较脚本不改。

N1 开始；尚未声明任何功能层通过。

## N1 测试实施（候选，尚未通过）

新增 DMA 适配器 2 例、AXI-Lite 主控 3 例、L2 DMA 定向 4 例与随机 2 例；另单独运行非法 DMA GetS 的 RTL 断言负例，要求进程失败且日志明确命中 l2_home 的端口 op 断言，不能把任意失败算作通过。两随机种子 51/52，各 2000 DMA（1000 Read/1000 MaskWrite）、至少 2000 CPU Get/Put、500 I Read，压力几何 sets=2/ways=2/slots=2。保留原 L8a 全部测试与规模。

代理黄金内存独立于 DUT；CPU store 按代理写入更新，DMA MaskWrite 按 WriteAck 更新，逐字节合并。为明确写入线性化点，同一行 I Read 与 DMA WriteAck 串行，异行 I/D/DMA 并发；同一行 D 副本仍经历真实 Inv/Down 和独立权限监视。DMA response 背压时逐拍校验保持，随机代理不改变原无 DMA 的 RNG 取样规则。

## N1 首轮动态证据

测试候选 SHA=9c2653023f6704841a28d48e9a1d6806e09cdef4，实际主机 cloud_chen@47.96.71.231；cwd=/home/cloud_chen/work/20261008-t10-9c265302；证据根 /home/cloud_chen/evidence/t10/9c265302。每项 manifest.json 记录实际命令、准确 SHA、主机、实时配置哈希、环境/资源预检；run.log、exit、results.xml 原样保留。断言 --assert 全程开启，未设置 SYNTHESIS。

| 证据子目录 | 结果 | 内容 |
| --- | --- | --- |
| n1-dma-adapter | exit 0，2/2 | Read/MaskWrite 字段、ID=0、1 credit、请求/响应保持、高位/IO/不存在地址直接报错 |
| n1-mmio-master | exit 0，3/3 | 全部自然对齐 lane 的 1/2/4/8 字节读写、符号扩展/FLW 装箱、AW/W 任意先后与背压、非 OKAY 精确 cause/tval |
| n1-l2-directed | exit 0，4/4 | UNIQUE 脏 Inv 合并、miss refill 合并、SHARED Inv、UNIQUE Down 最新值、读错误不安装、dma_write 精确来源 |
| n1-l2-random | exit 0，2/2 | seed51：75734 拍；seed52：76512 拍；各 DMA=2000、CPU Get/Put=2000、并发 I Read=500，另有最终 16 行读回 |
| n1-l2-op-assert | 外层 exit 0；负例 make exit 2 | 55ns 精确触发 l2_home.sv:348 的 DMA op 断言；日志原文及 negative-exit 保存，不计作正常用例通过 |

共 11 个正常用例和 1 个预期断言失败负例；XML 无正常 failure/error/skip。N1 的层通过还依赖本 SHA 的 L8a M1～M6 完整复跑，目前进行中，未标记 N1 层通过。T10 本 SHA 的 references/l9_fp.jsonl 已由批准的生成器创建，源/副本哈希与前述记录一致。

### 下层 M5 已通过，Y11 观察保持原失败点

同一候选 SHA 的 lower-m5-build exit0；mem_pipes=1 的 13 个目标（14 个程序）全部 exit0，自查和严格退休截止前缀与 T09 参考一致。其中 l9_fp 使用批准迁移副本，前缀 614 事件（613 retire+1 trap）、合法尾部 1；周期 2361。所有其他参考未改。

lower-m5-run-l10-vm 是独立的既有问题观察，make exit2，不计为正常门禁通过。首个失败点同 T09 最终报告：PC0x800001f8/order6285/cycle16678 的 PTE 普通 load 返回 0x20040c07，PC0x800001fc 掩码后得到0，PC0x80000200 准备期望0x40；PC0x80000204/order6288/cycle16688 分支到 fail，最终 PC0x80000420 写 tohost=3。N2/N3 仍需按 Y11 复现并修复；不能在此提前修 B36。

### 下层 M6 已通过

同一候选 SHA 的 lower-m6-build exit0，默认配置 mem_pipes=2/MSHRS=4/RFO=1 的 13 个既有目标（14 个程序）全部 exit0、严格退休前缀相同；run-l8a-mem exit0，自查+tohost=1、独立架构参考 62785 事件逐条一致，合法同拍尾部1，总退休62786，123750周期。统计 MSHR_sum=71657、平均0.579046、RFO发出932/有用931、bank_replays=190、probes=1、writebacks=2471，全部保留原规模且非零。lower-prefix-checker 的既有5例全部通过。M6 VM观察 make exit2，为同一 A 位读回既有问题，不计正常通过。

下表仅记录周期变化，无性能门槛；截止前缀均一致（包含 trap 类型、cause/tval 与合法尾部规则）。

| 程序 | M5周期 | M6周期 | 前缀事件 |
| --- | --- | --- | --- |
| dcache_data | 589 | 583 | 7 |
| dcache_replay | 597 | 597 | 6 |
| l10_ad | 16404 | 16404 | 6249 |
| l10_priv | 4047 | 4047 | 436 |
| l3_branch_dense | 2478 | 2477 | 365 |
| l7_predict_a | 44296 | 44300 | 19393 |
| l7_predict_b | 44362 | 44345 | 19444 |
| l7b_rvc | 6361 | 6361 | 2213 |
| l9_fp | 2361 | 2354 | 614 |
| l9_fp_smoke | 1370 | 1387 | 264 |
| replay-integer | 624 | 624 | 18 |
| rv64i_instructions | 576 | 576 | 14 |
| icache_smoke | 545 | 545 | 4 |
| unified_memory | 630 | 630 | 18 |

### 下层 M4 wrapper 编译遗漏修复

9c265302 的 M1/M2/M3 共13次117例全部通过；M4 seed1 的 LQ/SQ/LSU 18例通过。随后 lower-m4-load_store_unit_l5-s1 编译 exit2，在 load_store_unit_l5_tb_top.sv:43 漏接 atomic_i、heu_valid_i、heu_ready_o、heu_req_i、heu_resp_o、sq_kind_o 六端口。与常规 LSU wrapper 相同，将普通访存的 atomic_i/HEU valid/request 绑定0、未使用输出显式留空；不改 DUT RTL、不改测试刺激/黄金值/规模/种子。编译失败日志保留。

该接口连接修复不属于旧行为黄金迁移，未引入架构变化；此前通过套件的 RTL、wrapper 和刺激文件逐字节未变，复用已有证据并在新候选 SHA 继续剩余 M4。最终 spec12.8 仍必须全部在最终同一 SHA 重跑。
