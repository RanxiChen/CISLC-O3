# Verilator 下 ICache 测试方案

## 1. 当前仓库现状与测试切入点

基于当前仓库，可以明确看到 ICache 已经不是“纯 lookup 骨架”，而是已经进入了需要围绕 miss/refill/flush/replay 来系统验证的阶段。

当前与测试直接相关的文件有：

- `rtl/frontend/icache.sv`
  - 顶层模块名为 `ICache`
  - 输入请求接口：`s0_valid / s0_ready / s0_pc`
  - 下级 refill 接口：`refill_req_valid / refill_req_pc`、`refill_resp_valid / refill_resp_pc / refill_resp_error / refill_resp_data`
  - 输出接口：`out_valid / out_hit / out_pc / out_data / out_error`
  - 状态机：`ICACHE_WORK / ICACHE_REQ / ICACHE_WAIT / ICACHE_DONE`
- `rtl/common/o3_sram.sv`
  - data/tag array 的仿真 SRAM 模型
  - 同步单端口，posedge 写，`data_o <= SRAM_MEM[addr_i]`
  - `O3_SIM` 下支持 `INIT_FILE`
- `rtl/common/lfsr.sv`
  - replacement victim 选择相关
- `doc/icache.md`
  - 已经把 PC 字段划分、refill pulse 协议、flush 语义、miss/refill 状态机写清楚了
- `sim/icache/Makefile`
  - 当前 Verilator 入口
  - 已编译 `o3_sram.sv`、`lfsr.sv`、`icache.sv`
  - 当前 define 含 `O3_SIM`、`O3_ICACHE_DEBUG`、`O3_ICACHE_WAY0_VALID`
- `sim/icache/tb_icache.cpp`
  - 当前已有一个 C++ all-hit test
  - 主要覆盖初始化阵列命中路径
  - 使用了 `dbg_s1_set_idx / dbg_s1_bank_idx / dbg_s1_tag / dbg_s1_way_hit`

这意味着当前最合理的策略不是推翻已有测试，而是：

1. 保留并固化现有 all-hit test，作为最基础的 smoke/sanity test。
2. 在 Verilator C++ testbench 上继续扩展，逐步补齐 miss/refill/error/flush/replay/replacement。
3. 把“单用例脚本”提升为“可组织回归的一套 testbench 框架”。

---

## 2. 对当前已有测试的判断

`sim/icache/tb_icache.cpp` 当前本质上是在做“way0 预初始化命中验证”：

- 依赖 `O3_ICACHE_WAY0_VALID`
- 依赖 `o3_sram` 的初始化内容
- 遍历 `64 sets x 4 banks`
- 检查：
  - `out_valid == 1`
  - `out_hit == 1`
  - `out_pc` 正确
  - `out_data` 正确
- 并利用 debug 信号做辅助打印

这个测试有价值，原因是它已经验证了：

- set/bank/tag 位切分基本一致
- data bank 选择逻辑基本一致
- `s0 -> s1 -> out` 的 hit 路径能通
- 当前 `FETCH_BYTES == 16` 的 fetch 宽度假设在 happy path 下成立

但它明显没有覆盖下面这些正在开发阶段最容易出问题的内容：

- miss 何时产生
- `refill_req_valid` 是否只打一拍
- `refill_req_pc` 是否是 line-aligned
- `WAIT` 状态是否正确阻塞新请求
- `refill_resp_error` 时是否禁止写回且 `out_error=1`
- `flush` 打在 `REQ/WAIT/DONE` 时是否符合 `doc/icache.md`
- replay buffer 是否只缓存一个后续请求且能在 `DONE` 后重新送回 lookup
- invalid-way 优先与 LFSR replacement 是否符合预期

所以测试工作重点应当从“只看命中结果”扩展成“验证完整控制流程”。

---

## 3. Verilator 下的总体测试策略

建议分三层推进。

### 阶段 A，先保住当前 all-hit

目标：不破坏现有命中路径。

做法：

- 保留当前 `tb_icache.cpp` 的 all-hit 遍历测试
- 把它明确命名为 `all_hit_basic`
- 每次改 ICache 时都先跑它，确保基础寻址和输出格式没回归

这是最便宜、最稳的回归底线。

### 阶段 B，补齐“定向状态机测试”

目标：覆盖当前 `ICACHE_WORK/REQ/WAIT/DONE` 控制路径。

这部分以 directed test 为主，因为当前协议清晰、状态机规模不大，最适合用手工构造激励和预期结果。

优先补的内容：

1. cold miss + 正常 refill
2. miss + refill error
3. `WAIT` 期间拒绝新 `s0`
4. miss 同拍后续请求进入 replay
5. `flush` 打在 `WORK`
6. `flush` 打在 `REQ`
7. `flush` 打在 `WAIT`
8. `flush` 打在 `DONE`
9. invalid way 优先替换
10. set 全 valid 后 replacement 走 LFSR

### 阶段 C，做小规模随机回归

目标：发现 directed case 之间交错时的问题。

做法：

- 随机生成 line 地址流
- 随机插入 miss/hit 场景
- 随机给 refill response latency
- 随机插入 `flush`
- 随机给一部分 `refill_resp_error`
- 用软件参考模型做 scoreboard 对比

当前 ICache 还是单 outstanding miss，状态空间不算大，所以随机测试不需要一步上复杂约束随机，简单 PRNG 驱动就足够有价值。

---

## 4. 建议的 testbench 结构

虽然当前只有一个 `tb_icache.cpp`，但建议逻辑上把 testbench 拆成下面几层。即使暂时仍写在一个 cpp 里，也最好按这些职责组织代码。

### 4.1 driver

职责：驱动 DUT 端口。

建议封装的操作：

- `reset(ncycles)`
- `tick()`
- `drive_s0_req(pc)`
- `clear_s0_req()`
- `send_refill_resp(pc, data, error)`
- `pulse_flush()`
- `wait_cycles(n)`

这样可以把“时钟怎么翻”“在哪个边沿拉高 pulse”统一起来，避免每个 case 自己拼时序。

### 4.2 monitor

职责：采样 DUT 的可观察行为。

建议每拍记录：

- `state` 的外部可推断变化（虽然没有直接输出 state，但可以从接口行为与 debug 信号推断）
- `s0_valid/s0_ready/s0_pc`
- `refill_req_valid/refill_req_pc`
- `refill_resp_valid/refill_resp_pc/refill_resp_error`
- `out_valid/out_hit/out_pc/out_data/out_error`
- debug 口：
  - `dbg_s0_fire`
  - `dbg_s1_valid`
  - `dbg_s1_pc`
  - `dbg_s1_set_idx`
  - `dbg_s1_bank_idx`
  - `dbg_s1_tag`
  - `dbg_s1_way_hit`
  - `dbg_out_valid`
  - `dbg_out_hit`

### 4.3 reference model

建议写一个轻量软件模型，不需要模拟 RTL 细节，但要模拟架构语义：

- cache line state：`valid + tag + line_data`
- 单 outstanding miss
- 单 replay buffer
- invalid 优先，否则按可控 victim 规则替换
- flush 时按 `doc/icache.md` 的语义丢弃当前 miss 内部效果

参考模型的核心价值不是“比 RTL 更复杂”，而是提供自动判定预期输出的能力，让随机测试能跑起来。

### 4.4 scoreboard

职责：比较参考模型与 DUT 的外部行为。

建议比较：

- `out_valid`
- `out_hit`
- `out_pc`
- `out_data`
- `out_error`
- `refill_req_valid`
- `refill_req_pc`

特别注意：对 pulse 信号的比较必须做“按周期比对”，不能只在 case 结束时检查最终值。

### 4.5 helpers

建议单独封装：

- 地址字段拆分 helper
  - `get_set(pc)`
  - `get_bank(pc)`
  - `get_line_pc(pc)`
  - `make_pc(tag, set, bank)`
- line data 生成 helper
  - 例如根据 `line_pc` 生成 deterministic 的 64B line，方便检查 bank slice 是否正确
- pretty print helper
  - 格式化 128-bit `out_data`
  - 格式化 line data

### 4.6 tests

每个 test case 独立成函数，例如：

- `test_all_hit_basic()`
- `test_miss_refill_success()`
- `test_miss_refill_error()`
- `test_flush_during_wait()`
- `test_replay_after_miss()`
- `test_invalid_way_priority()`
- `test_lfsr_replacement()`

主函数负责顺序运行并汇总 pass/fail。

---

## 5. `refill_req / refill_resp` 的驱动与检查方法

这是当前测试最关键的部分。

### 5.1 request 侧应该怎么测

根据 `doc/icache.md`，当前 refill request 是 pulse 协议，不是 ready/valid 握手。

因此要验证：

- miss 发生后，`refill_req_valid` 只拉高一个周期
- `refill_req_pc` 必须等于 miss PC 的 line-aligned 地址
- request 发出后，DUT 进入等待 response 的阶段

建议检查点：

1. 先送一个确定 miss 的 `s0_pc`
2. 观察后续周期里何时出现 `refill_req_valid == 1`
3. 在该拍检查：
   - `refill_req_pc == get_line_pc(miss_pc)`
4. 下一拍检查 `refill_req_valid` 已经回到 0

### 5.2 response 侧应该怎么驱动

建议 testbench 提供统一 helper：

- `send_refill_resp_once(line_pc, line_data, error)`

它的语义是：

- 在一个周期内把 `refill_resp_valid=1`
- 同时驱动：
  - `refill_resp_pc = line_pc`
  - `refill_resp_data = line_data`
  - `refill_resp_error = error`
- 下一周期自动清零 `refill_resp_valid`

### 5.3 response 侧应该怎么检查

成功 refill 时需要检查两类事情。

第一类，协议级：

- response 回来前 DUT 不应该提前给 miss 的最终数据
- response 回来后应进入 `DONE`
- `DONE` 拍应输出：
  - `out_valid = 1`
  - `out_pc = miss_pc`
  - `out_error = 0`
  - `out_data = refill line 中 miss_bank 对应的 16B`

第二类，状态保持：

- refill 成功后，相同 `set/tag/bank` 的再次访问应命中
- `out_hit` 应为 1
- 不应再次发 `refill_req_valid`

错误 refill 时则要检查：

- `out_valid = 1`
- `out_pc = miss_pc`
- `out_error = 1`
- `out_data` 为全 1
- 随后对同一 PC 再访问，应仍然 miss，而不是假命中

---

## 6. 关键测试用例清单

下面这些用例建议按优先级逐个补齐。

### 6.1 基础命中路径

#### 用例 1，all-hit basic

目标：保留当前已有测试价值。

检查点：

- 遍历 `set=0..63`、`bank=0..3`
- `out_valid/out_hit/out_pc/out_data` 正确
- `dbg_s1_set_idx/dbg_s1_bank_idx/dbg_s1_tag/dbg_s1_way_hit` 与预期一致

这是当前 smoke test。

---

### 6.2 miss/refill 主流程

#### 用例 2，cold miss then refill success

步骤：

1. 复位后访问一个未命中的 PC
2. 检查进入 miss 流程并发出 `refill_req_valid`
3. 返回正确 line 的 `refill_resp_valid`
4. 检查 `DONE` 拍输出 miss 对应 bank 数据
5. 再访问同一 PC，应直接 hit

重点检查：

- `refill_req_pc` 必须 line-aligned
- `out_data` 必须是 64B line 中对应 bank 的 16B slice，而不是整条 line 或错误 bank

#### 用例 3，miss with refill error

步骤：

1. 制造 miss
2. 返回 `refill_resp_error=1`
3. 检查 `DONE` 拍：
   - `out_valid=1`
   - `out_error=1`
   - `out_data=all_ones`
4. 再访问同一地址，仍应 miss

这个用例非常关键，因为它直接验证“error response 不得写回 cache”。

---

### 6.3 flush 相关

#### 用例 4，flush in WORK

步骤：

1. 先建立若干命中项
2. 拉一次 `flush`
3. 之后访问原本命中的地址

预期：

- valid 被清空
- 之前的 hit 应变成 miss
- 不要求 data/tag SRAM 清零，只验证 valid 语义

#### 用例 5，flush in REQ

步骤：

1. 制造 miss，使其进入 `REQ`
2. 在 request 发出阶段打 `flush`
3. 后续再送对应 response

预期：

- request 仍然被视为已发出
- response 回来只用于闭合协议
- 不写回 cache
- 不输出 miss 数据
- 后续同地址访问仍然 miss

#### 用例 6，flush in WAIT

步骤与上面类似，只是把 `flush` 打在 `WAIT` 期间。

这是最应该重点测的 flush 场景。

#### 用例 7，flush in DONE

步骤：

1. miss 请求已走到 `DONE` 前后
2. `flush` 与结果输出交错

预期：

- 按当前 `doc/icache.md` 语义，flush 应抑制当前 miss 输出和 replay

---

### 6.4 replay 相关

#### 用例 8，miss same-cycle with one trailing request

根据当前 RTL，`work_miss` 当拍若还有新的 `s0_fire`，会把该请求塞入单 entry replay buffer。

步骤：

1. 触发一个 miss
2. 在 miss 捕获时制造一个 trailing request
3. 完成 refill
4. 检查 `DONE` 之后 replay request 被重新送入 lookup

预期：

- replay 的 PC 正确
- replay 最终能命中或继续触发下一次 miss
- replay 只保留一项，不应神秘吞吐多个请求

#### 用例 9，flush clears replay

步骤：

1. 制造 miss 并缓存 replay
2. 在 `REQ/WAIT/DONE` 中间打 `flush`

预期：

- replay buffer 被清空
- refill 回来后不再 replay 该请求

---

### 6.5 replacement 相关

#### 用例 10，invalid way priority

步骤：

1. 选择某个 set
2. 先只填部分 way，使至少一个 invalid way 存在
3. 再制造新 miss 到同一 set

预期：

- victim 应优先选 invalid way
- 不应该无故替换已有 valid line

这个测试即使看不到内部 `miss_victim_way_q`，也可以通过“哪一条线最后仍存在”间接验证。

#### 用例 11，replacement when all ways valid

步骤：

1. 把同一 set 的所有 ways 填满不同 tag
2. 再送一个新 tag 的 miss
3. 观察后续哪一条旧 line 被替换掉

预期：

- replacement 行为稳定且符合 LFSR 驱动
- 至少要验证“确实发生了替换”，且替换后新 line 可命中

如果要更强地验证 LFSR 选择，可考虑在 testbench 中建立对 LFSR 序列的可预测假设，或者后续增加仅仿真可见的 victim debug 信号。

---

### 6.6 协议防呆类

#### 用例 12，response PC mismatch should fail

当前 RTL 在 `WAIT` 收到 response 时对 `refill_resp_pc == miss_refill_pc_q` 有 assert。

建议加一个负向测试：

- miss 一个 line
- 故意返回另一个 `refill_resp_pc`

预期：

- 仿真报错或失败退出

这个用例适合单独跑，不要混入普通 regression 的默认集合。

#### 用例 13，WAIT blocks new requests

步骤：

1. 进入 `WAIT`
2. 持续给新的 `s0_valid`

预期：

- `s0_ready` 应为 0
- 不应接收新请求
- 不应额外发新的 `refill_req`

---

## 7. 如何利用并保留当前 debug 信号

当前 `O3_ICACHE_DEBUG` 已经给出了很有价值的观测口，建议不要轻易删除。

当前最有价值的用途如下：

### `dbg_s0_fire`

用来确认请求何时真正被 DUT 接收。

### `dbg_s1_valid / dbg_s1_pc`

用来确认 `s0` 请求或 replay 请求何时进入 lookup 的下一阶段。

### `dbg_s1_set_idx / dbg_s1_bank_idx / dbg_s1_tag`

用来直接检查 testbench 的地址字段拆分和 DUT 是否一致。这对于排查“为什么明明像同一地址却没命中”非常省时间。

### `dbg_s1_way_hit`

用来判断：

- 是不是多个 way 同时命中
- 预期命中的到底是哪一 way
- replacement 后再次访问是否落到了正确的 way

### `dbg_out_valid / dbg_out_hit`

可帮助区分：

- 是 out 路径没起效
- 还是上游 lookup 本身没命中

建议：

- regression 默认保留这些 debug 打印能力，但只在失败时详细展开
- 成功日志使用精简模式，避免刷屏

如果后面允许加新 debug 信号，最值得补的是：

- 当前 miss 选中的 victim way
- 当前 refill 是否被 discard
- replay_valid/replay_pc

但在这份计划里，不要求现在就修改 RTL。

---

## 8. regression 与日志组织建议

### 8.1 regression 分层

建议至少分三档：

#### smoke

快速验证，默认每次改 RTL 都跑：

- `all_hit_basic`
- `cold_miss_refill_success`
- `miss_refill_error`

#### directed

覆盖完整状态机：

- smoke 全部
- flush 系列
- replay 系列
- invalid-way / replacement 系列
- WAIT block 系列

#### random

随机若干轮地址流、latency、flush、error 注入。

默认本地可先跑小轮数，CI 或夜间回归再加大轮数。

### 8.2 日志输出建议

每个 test case 建议统一打印：

- case 名称
- seed（若有随机）
- 失败时的 cycle 编号
- 输入刺激
- DUT 关键输出
- debug 口状态

失败日志建议长这样：

- `CASE=flush_in_wait`
- `CYCLE=123`
- `REQ_PC=...`
- `REFILL_REQ_PC=...`
- `RESP_PC=...`
- `OUT_VALID/HIT/ERROR=...`
- `DBG_SET/BANK/TAG/WAY_HIT=...`

这样定位问题会快很多。

### 8.3 波形策略

建议默认不开 VCD，失败时再开，或者提供开关：

- 平时回归：只看文本日志，速度快
- 失败复现：打开波形，只跑单 case

如果后续要做随机测试，这一点尤其重要，否则 Verilator 跑速会明显下降。

---

## 9. 建议的目录与脚本结构

这部分是建议结构，不要求现在全部创建。

```text
sim/icache/
├── Makefile
├── tb_icache.cpp                  # 现有入口，可逐步重构
├── include/
│   ├── icache_tb_driver.h
│   ├── icache_tb_model.h
│   ├── icache_tb_scoreboard.h
│   └── icache_tb_helpers.h
├── tests/
│   ├── test_all_hit.cpp
│   ├── test_miss_refill.cpp
│   ├── test_flush.cpp
│   ├── test_replay.cpp
│   ├── test_replacement.cpp
│   └── test_random.cpp
├── data/
│   ├── golden_lines/
│   └── seeds/
└── obj_dir/
```

如果暂时不想拆太多文件，也建议先在 `tb_icache.cpp` 内部按以下 section 重构：

1. 时钟与 reset helper
2. 请求/response driver helper
3. 参考模型结构体
4. 通用检查函数
5. 单个 directed cases
6. 回归入口

---

## 10. 推荐的实施顺序

如果按投入产出比排序，我建议这样推进：

### 第一步，固化当前 all-hit case

先把现有 `tb_icache.cpp` 的 all-hit 用例保住，不要因为后面加复杂逻辑把基础命中路径搞坏。

### 第二步，加一个最小 miss/refill success case

这是当前最重要的增量验证，因为 ICache 已经有 `REQ/WAIT/DONE` 了。

### 第三步，加 refill error + flush in WAIT

这两个是最容易埋 bug 的地方，也最能验证 `doc/icache.md` 里的协议语义是不是真的落地了。

### 第四步，加 replay case

当前 replay 是单 entry，而且和 `DONE` 路径耦合，值得尽早锁住行为。

### 第五步，加 invalid-way / replacement case

这一步更多是在功能趋稳后补齐替换策略验证。

### 第六步，再做随机回归

等 directed case 比较完整后，再上随机测试，收益最大。

---

## 11. 一个务实的结论

如果只看当前仓库状态，最合适的 Verilator 测试路线不是一下子追求“完整 UVM 化”，而是：

- 继续沿用 `sim/icache/tb_icache.cpp` 的 C++ testbench 形式
- 先把已有 all-hit case 变成稳定回归基线
- 再围绕 `doc/icache.md` 里已经定义好的 miss/refill/flush/replay 语义，补 directed cases
- 最后再用一个轻量 reference model 支撑随机回归

这样做的好处是：

- 和当前仓库最贴合
- 对 Verilator 友好
- 能快速验证 ICache 正在开发的关键控制逻辑
- 不需要先重构整套仿真基础设施

对于当前这版 ICache，最关键的不是“测试框架多华丽”，而是尽快把下面四件事测扎实：

1. miss 后 request/response 脉冲是否正确
2. refill 后 bank slice 和输出是否正确
3. flush 是否真的按文档语义丢弃内部效果
4. replay 和 replacement 是否符合预期

这四项一旦测稳，后续继续开发 icache，心里就会踏实很多。