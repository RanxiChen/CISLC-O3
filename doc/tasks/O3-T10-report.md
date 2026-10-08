# O3-T10 L8b 实施报告（进行中）

当前停点：N3全部通过，下一步合并并行窗口并执行N4；Y11/B36已按用户批准修复，原VM_AD=1在mem_pipes1/2都通过。2026-10-08起按任务书加速修订执行，中间层使用结果表和失败修复记录；完整审计留到最终12.8。此前章节中的等待审批、全量下层与快照记录是历史状态。

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

## N1 层通过

新增11个正常用例+1个精确 DMA op 断言负例通过；L8a 下层 M1～M4 共48次237例全部通过，MSHR=1/4、RFO=0/1、压力/默认几何、固定种子1/7/29和原有规模保持不变；M5/M6 共29个程序通过自查与严格截止前缀，前缀比较器既有5例通过。Y13 开启。VM 的两配置只记录既有失败观察，按 Y11 留待 N2/N3，不误计通过。

证据候选9c2653023f6704841a28d48e9a1d6806e09cdef4覆盖 N1、M1～M3、M4前3套、M5/M6；0fc47e4d2e50fbbdd09953ecb8034ee65f8dd8c6覆盖补接 wrapper 后的剩余 M4。两候选逐文件 Git diff 仅含报告与 L5 wrapper 的6端口连接，全部 RTL 和其他测试源码逐字节相同，RTL 固定为 dc261d24。不存在 RTL 修复后漏跑下层。完整 n1-layer-audit.json 记录逐项 SHA/次数/用例数；日志/XML/退出码/参考/退休 trace 保留于 /home/cloud_chen/evidence/t10/{9c265302,0fc47e4d}，本地完成快照 /tmp/o3-t10-evidence/<对应SHA前8位>/completed-evidence-snapshot.tar.gz。最终同 SHA 总门禁尚未执行。

N1 通过后继续 N2，不开始 N3。

## N2 测试实施（候选，尚未通过）

cache wrapper 增加上下文选择及 reservation 清除输入、只读 reservation/保护窗口/原子安装保持/DMA 广播监视；未启用测试上下文选择时仍为既有 M 态，所有旧刺激字段的默认打包位保持逐位一致。新增9个 AMO 运算独立用例（.W偏移0/4、.D，5组边界输入，8字节整词检查另一半不变）、miss/升级/refill错误、RMW同行probe、WAIT共享者Inv/INSTALL保持、LR/SC精确配对/一次成功、reservation清除表、窗口内SC与DMA广播、IO/PMA/页错误/取消、权限寄存与上下文切换、实际Y11 PTE值的访问序列。

权限变化测试先排空旧请求并flush再切上下文，遵循核的串行合同；Y13断言始终开启。Y11使用实际PA0x80102038、旧PTE0x20040c07与期望0x20040c47。若cache单模块未复现整核的旧值读回，按spec继续在N3组合时序中定位，不改B36。

### N2 首轮失败（b4fdff00，cloud_chen）

MSHR=1 的 n2-cache-m1 共18例，14例通过；DMA广播新测试错误地要求广播与InvAck同拍，实际前一拍广播（107）、后一拍Ack（108）。冻结spec要求广播与tag置I同拍，与Ack无此要求。修正新测试代理在每个时钟沿前采样广播/原状态、沿后严格检查tag=I，并要求唯一广播/正确行/M→I，保留SC成功、脏应答与全行黄金数据断言。不是旧测试迁移或黄金常量更改。9个AMO用例另设置各自qualname以便日志/XML唯一命名，操作、5组输入和断言完全不变。

随后取消用例在43857ns触发dcache.sv:430的atomic install retry exceeded bound；最后两例由于仿真终止尚未执行，不计作独立功能失败。取消用例发出AMO GetM后flush，释放迟到授权，要求50拍内没有RMW/reservation且读取原值；该原断言和规模保持。根因：line transaction 的atomic标记跨flush保留，安装迟到行后仍启动待重发保护，但HEU已取消，不再重发，16拍界限触发。须修RTL，保持断言16不变；不涉及B36。

### N2 RTL 修复：取消后迟到安装不再启动原子重发保护

独立复现 n2-cancel-repro 在 b4fdff0059775ed937a6582187bd5b7b6d8c8cbe、cloud_chen、1646ns 同样触发 dcache.sv:430 的16拍界限断言，排除前一失败用例的影响。准确复现命令见该项manifest.json：make -j4 -C sim/cocotb/dcache MSHRS=1 COCOTB_TEST_MODULES=test_l8b_dcache COCOTB_TESTCASE=io_fault_alignment_page_fault_and_pre_effect_cancel SIM_BUILD=/home/cloud_chen/evidence/t10/b4fdff00/n2-cache-m1/build COCOTB_RESULTS_FILE=/home/cloud_chen/evidence/t10/b4fdff00/n2-cancel-repro/results.xml。

dcache 为每个MSHR增加 atomic_live_q：原子分配/仍存活的原子合并等待建立，flush清除，安装完成释放。迟到一致性请求继续按原协议完成，保留 transaction.atomic 的 WAIT probe 前进规则；只有当前存活的 HEU 原子请求在成功安装后启动 Y5 重发保护。安装与flush同拍也禁止启动。保留原16拍断言和两拍RMW断言，不延长窗口，不改B36。RTL修复独立提交，随后重跑 N1 与 L8a M1～M6 和当前N2。

### N2 修复后的复跑与组合 wrapper 连接

RTL修复提交7c0b58cee53d73c863a61a277e4859732a369480，在cloud_chen的n2-cache-m1与n2-cache-m4各18例全部通过，lint exit0、0 errors（359 warnings原样保留），N1正常11例通过。下层M1共23例、M2共54例通过；M3编译报memsys_tb_top.sv:70的cache实例漏接新增9个测试端口。补齐上下文/清reservation的常量M态输入，并显式留空监视输出。同步检查共享CacheBench的另一个消费者pte_cache_tb_top，为其补同名输入和监视输出，默认上下文仍为M态。全部DUT RTL、原刺激、断言、规模和种子不变；不属于黄金迁移。失败日志保留，继续重跑其余下层。

补充两例增强取消和清除表的区分：LR GetM已实际发出后flush，迟到安装50拍内每拍无reservation/原子重发保护且读回未变；同行PTE CAS比较不匹配时无成功写、reservation保留并可成功SC。原18例不变，N2完整套件现为20例。

### N2 完整复跑结果

全部运行主机cloud_chen@47.96.71.231，每项运行前重新读取共享配置并预检；工具与前述版本相同，Y13/Verilator --assert全程开启。RTL固定为7c0b58cee53d73c863a61a277e4859732a369480。候选36a04c9e2e2f680d0d6c71b1b0d3c214e3d96758只补两测试wrapper接口，643307af7546115027ce295751e67d3368a49fa1另加上述两例与报告，其他RTL及原测试刺激均逐字节相同。

| 候选/证据根 `/home/cloud_chen/evidence/t10/` | 完整通过范围 | 结果 |
| --- | --- | --- |
| 7c0b58ce | M1/M2、N1正常与断言负例、M5/M6、lint | M1/M2共5次77例；N1正常11例及精确负例；M5/M6共29程序；lint0 errors、359 warnings |
| 36a04c9e | M3、退休比较器 | 8组合各5例，共40例；固定61/62种子各2000 CPU+500 I Read，压力/默认、MSHR1/4、RFO0/1全部保留；比较器5例 |
| 643307af | M4、N2 | M4共35次120例，固定1/7/29种子；N2 MSHR1/4各20例，正常XML无failure/error/skip |

MSHR1的新20例首次调用未覆盖Makefile旧名称筛选，进程exit0但XML为0例；证据`n2-cache-m1`保留，此运行明确拒绝计入通过。显式以COCOTB_TEST_MODULES=test_l8b_dcache、COCOTB_TESTCASE=运行完整新模块，`n2-cache-m1-full`真实20例通过；MSHR4的`n2-cache-m4`真实20例通过。未修改原MSHR1用例筛选、任何断言或规模。逐项审核`n2-layer-audit.json`校验准确SHA、host、cwd、命令、exit、XML条数/失败/跳过；完整日志/XML/退休trace/参考/哈希保留，三个候选均有本地completed-evidence-snapshot.tar.gz。

M5/M6严格截止前缀与N1时记录全部一致，周期数也相同；M6 l8a_mem仍为123750周期、有效前缀62785、合法尾部1，MSHR/RFO/bank/probe/writeback统计均非零且相同。原T09参考及批准的l9_fp副本不再改动。RTL修复后下层M1～M4共48次237例、M5/M6和N1完整复跑，未漏下层。

Y11：两配置run-l10-vm仍tohost=3（make exit2），首个失败仍PC0x800001f8返回0x20040c07、PC0x80000204跳fail。额外`n2-y11-core-debug`使用已有L10_DEBUG/L8A_AD_DEBUG，直接驱动exit1原样保留，不计作通过。N2单cache的实际PTE值序列在A更新完成后普通load正确返回0x20040c47，未复现整核的旧值；按12.2/12.3表规定，继续在N3检查组合访问时序，尚未改B36，未声称VM修复。

## N3 开始：Y11 只读时序定位

仿真顶层增加L8B_PTE_DEBUG日志，仅在明确plusarg启用时输出PTW交付、PTE更新握手、cache实际写入、目标VA0x7000/PA0x80102038的cache判定。监视没有DUT输入或状态修改，未改RTL、程序或黄金值，用于将普通PTE load与A更新的顺序绑定准确周期；尚未声明N3通过。

### Y11 根因与 B36 合同停止点

动态监视候选2a05dca078790424fceff500654d8673d4dd351c，实际主机cloud_chen，cwd=/home/cloud_chen/work/20261008-t10-2a05dca0。n3-y11-build编译exit0；n3-y11-core-confirm驱动exit1、tohost=3。原程序和自查完全不变，VM_AD=1，Y13开启。ordering-proof.json逐条断言目标PA、原值/新值、唯一匹配次数、顺序及退休记录；其日志/trace哈希在该文件内。此处不是PTW漏写A，也不是cache写后读旧数据。

| 实际执行拍 | 事件 |
| --- | --- |
| 16655 | 年老VA0x7000 load（ROB1）DTLB miss |
| 16661 | PTW读叶PTE PA0x80102038，返回0x20040c07 |
| 16663 | 年轻普通PTE load（ROB4）提前执行，返回0x20040c07 |
| 16664 | cache接受该PTE A更新请求，expected=0x20040c07、set_a=1、set_d=0 |
| 16669 | PS真实写入0x20040c47（A=1、D=0） |
| 16671 | PTW交付可用翻译，pte=0x20040c47、A=1、D=0，无fault |
| 16676 | 年老VA0x7000 load访问PA0x80103000并得到0x11223344 |
| 16678 | 年老load在order6282退休；年轻PTE load在order6285/PC0x800001f8退休，保留其提前读到的旧值 |
| 16688 | order6288/PC0x80000204跳fail，最终tohost=3 |

首个失败用例：run-l10-vm（VM_AD=1），sim/o3/tests/l10_vm.S:121的PTE读回在:122掩码后为0、:123期望0x40、:124分支失败。冻结B36在doc/design/CISLC-O3-BACKEND-DESIGN-BASELINE.md:632只要求A更新完成后交付翻译，实际16669→16671→16676已经满足；:633定义了D=0年轻访存排序，未定义A更新后已执行的年轻PTE load重放。冻结L8b spec第10节:258的order_flush触发仅为dma_write Inv，不含内部PTE A写入。由此判断，若保持原程序/黄金值，必须补充内部A更新与显式PTE load的排序合同，不能擅自扩大DMA触发定义。

已经尝试的定位：N2顺序“CAS完成→普通load”返回新值；N3整核时序监视两次得到相同早读/后写顺序。首次debug命令含set -e使SSH外壳在驱动exit1时提前退出、没有写外层exit文件，原日志保留，未伪称其完整交付；n3-y11-core-confirm重新执行、去除errexit，明确记录exit1与相同首个失败点。确认运行ELF SHA256=56488a189a8cdb91fcb3990508c4999f174f7428938883100442469ca09429da；既有M5 ELF SHA256=43ba45b93280faa4821b073d91ccd8230a989b4e2ae5061f6fe1edc6ca9d8408。两者整体哈希不同；ordering-proof.json逐段校验所有PT_LOAD的地址、文件/内存大小和加载字节完全相同，差异位于非加载内容，不是程序迁移。

N3组合路径另有候选7e5721a2f399e6ad46384a3d076380cb80220165，新增test_l8b_y11_repro.py，仅复现已观察的物理访问顺序，不修改原VM程序或其黄金值。cloud_chen上的n3-y11-memsys-pressure-m1与n3-y11-memsys-default-m4各1个诊断用例exit0、XML无failure/error/skip：PTW先读旧PTE，年轻普通load在CAS之前读旧值，CAS成功后数据load及新的PTE load读到正确新值。此诊断区分cache正常早读响应与核级缺失重放，不把原VM失败改判通过。N3随机AMO/LR/SC/DMA门禁尚未加入/通过，当前因B36合同停止点暂停后续实现。

准确复现（环境激活、该SHA独立cwd下执行；完整命令和实时主机配置见n3-y11-core-confirm/manifest.json）：

```sh
source /home/cloud_chen/setup/activate-o3.sh
cd /home/cloud_chen/work/20261008-t10-2a05dca0
env -u O3_INJECT /home/cloud_chen/evidence/t10/2a05dca0/n3-y11-build/build/Vo3_tandem_top +L7_CHECK +L8B_PTE_DEBUG --image /home/cloud_chen/evidence/t10/2a05dca0/n3-y11-core-confirm/l10_vm.elf --trace /tmp/l10_vm-repro.jsonl --tohost-address 0x801ff000 --max-cycles 200000 --max-retires 20000
```

### 待用户批准的具体合同补丁（尚未修改 spec/design/RTL）

建议在B36的A更新条款后增加：

> 成功把PTE的A位从0置1时，在cache实际写入的同拍向LQ广播该PTE物理行。已执行、未退休的同行普通load（包括SQ转发的load）必须标记order_flush；同拍完成的load结果也不能漏标。被取消、有异常或由HEU完成的load沿用现有排除规则。到ROB队头按既有refetch流程冲刷该load及更年轻指令并重取。比较不匹配、写入失败、写前取消不产生此广播。内部PTW更新仍不受HEU队头门控，常用命中路径不增加流水级。

相应在冻结L8b spec第10节增加这一内部成功A更新触发，并明确它与DMA Inv分别接入、同拍两个不同物理行均不得丢失；不伪造dma_write位，不计DMA事务/读写事件，实际重取仍计ld_order_flush。D=0的既有队头合同保持。N3加入已观察顺序的回归，N4补两来源同拍/排除/队头重取测试，原VM程序、自查及trap计数全部保留。具体端口编码与仲裁可在批准后自行决定并记录。

此建议要求修改冻结spec及doc/design的B36，触发任务书停止条件，当前仅写入本报告供审批。未实施上述RTL，不宣称N3通过，不进入N4/N5/N6，不推送origin、不开始L8c。

## B36 / Y11 用户批准补丁实施

用户已批准前述具体合同补丁并要求继续到 N6。同步 B36 与 L8b 第10节；DCache 在成功的物理 A 0→1 写入拍独立输出 pte_a_write/pte_a_line，LQ 对两个来源分别匹配，包含同拍普通 load 完成、SQ 转发结果。DMA 位与事件不复用。比较失败、权限失败无 PS 写入因而无广播。保留现有不可撤销写入边界与内部 epoch 判定。尚未声明修复通过，随后在准确 SHA 上运行 lint、下层 M1～M6/N1/N2，并确认原 run-l10-vm。

### B36 首轮整核复跑：退休前缀漏拦截

92659708 的 lint/M1/M2/N1/N2 通过，M5/M6 既有29程序自查和严格截止前缀通过，l8a_mem周期123750/前缀62785/尾部1。VM_AD=1 两配置仍tohost=3；y11-after-b36-debug保存原日志和trace。默认配置年轻PTE load c16649早读0x20040c07，成功A写c16655，翻译交付c16657，年老load c16662完成；c16664同拍四条退休包含ROB4/PC0x800001f8。根因为ROB只通过commit_ctrl的队头order_flush禁止整拍退休，退休宽度4的更年轻lane可跨过标记项。补充LQ的按ROB索引标记bitmap，ROB逐条退休前缀遇标记停止，只让更老连续前缀退休；标记load成为队头后沿现有同步/refetch流程重取。这实现已批准的“不退休、到队头重取”行为，不新增合同。首轮全部失败证据保留。RTL再修复后完整重跑下层。

### B36 修复后的 VM 确认（N3 诊断，非 N5 层验收）

RTL SHA db83a505baba87c4dadefa3686040d8669db0500，主机 cloud_chen，cwd /home/cloud_chen/work/20261008-t10-db83a505，证据 /home/cloud_chen/evidence/t10/db83a505。lint exit0、0 errors/359 warnings；N1正常11例及精确负例、N2 MSHR1/4各20例通过。M5/M6原有29程序自查与严格截止前缀全部通过。VM_AD=1在mem_pipes1与2均exit0/tohost1；默认17534周期、6434退休。y11-vm-confirm另用原l10_vm.S独立编译执行，exit0；y11-vm-proof校验PC0x800001f8唯一退休、值0x20040c47、先早读旧值/后实际A写入以及最终s3=6（trace有8条trap，包含不计入s3的ecall）；原自查、trap数规则、黄金值未修改。proof.json保存ELF/trace/log的SHA256。原失败记录保持于92659708。

N3随机代理保留独立AXI内存、架构字节黄金模型、实际握手权限/SWMR与目录监视、看门狗。每种几何/MSHR各种子71/72，每种子2000 CPU操作（load/STA/drain/9类AMO/LR/SC）、2000 DMA读写交替、500 I Read；额外检查LR→DMA Inv→SC失败及LR/SC成功。同物理行的I Read与DMA WriteAck串行以确定写入线性化点，异行I Read持续并发，L1D仍经历真实Down/Inv；不改变既有M3刺激序列或断言。A写广播诊断验证目标物理行与成功CAS写入拍完全一致。候选533ee73f仅测试代理改动，RTL沿用db83a505。下层复跑及N3四个组合已完成，结果如下。


## N3 层通过（加速修订）

每项实际主机均为cloud_chen@47.96.71.231，执行前读取共享主机配置并成功SSH预检；Verilator5.050/cocotb2.1.0，断言开启。下表SHA为实际代码候选，报告提交不改变RTL或测试。

| SHA | 主机 | 命令（完整参数见运行日志/文本记录） | exit | 用例数 |
| --- | --- | --- | --- | --- |
| 533ee73f | cloud_chen | make -j4 -C sim/cocotb/memsys GEOMETRY=pressure MSHRS=1 RFO=1 COCOTB_TEST_MODULES=test_l8b_memsys,test_l8b_y11_repro | 0 | 3 |
| 533ee73f | cloud_chen | 同上 GEOMETRY=pressure MSHRS=4 | 0 | 3 |
| 533ee73f | cloud_chen | 同上 GEOMETRY=default MSHRS=1 | 0 | 3 |
| 533ee73f | cloud_chen | 同上 GEOMETRY=default MSHRS=4 | 0 | 3 |
| db83a505 | cloud_chen | make -j4 -C sim/cocotb/rob | 0 | 4 |
| db83a505 | cloud_chen | python3 /tmp/o3-t10-tools/lower.py db83a505baba87c4dadefa3686040d8669db0500；N1/N2驱动 | 0 | M1–M4 237；N1 11正常+1负例；N2 40 |
| db83a505 | cloud_chen | python3 /tmp/o3-t10-tools/m6.py db83a505baba87c4dadefa3686040d8669db0500 | 0 | M6全部目标及VM_AD=1，共16程序 |
| db83a505 | cloud_chen | make lint | 0 | 0 errors，359 warnings |

N3共12例，所有XML均无failure/error/skip。证据根为/home/cloud_chen/evidence/t10/{533ee73f,db83a505}；四个N3目录分别为n3-pressure-m1、n3-pressure-m4、n3-default-m1、n3-default-m4，ROB为n3-direct-rob。B36与退休前缀的失败→根因→RTL修复见前两节；直接涉及cache/LQ/ROB下层均已通过，修订生效前额外完成的全下层结果保留为历史证据。

### 自行决定

- 新N3代理按DMA WriteAck线性化同物理行的I Read，排空已发出的同行I请求并暂缓新的同行请求；异行保持并发，黄金内存值、规模、种子和目录断言未变。修复握手采样同时检查实际I valid。
- 默认几何/MSHR4发生两个驱动重复启动，属于本窗口调度错误；取消其中一个，保留另一实例完整3例exit0/XML结果。取消驱动的143与日志中的Terminated不计作DUT失败或通过。最终总门禁使用全新候选目录。
- 加速修订之后不新增中间审计JSON、哈希清单、快照包或字节一致性证明；ROB直接套件使用文本SHA/主机/命令/exit记录。
