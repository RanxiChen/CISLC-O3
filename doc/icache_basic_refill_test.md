# ICache 最基本 Refill 测试讨论稿

## 目标

这份文档只讨论一个**非常基础**的 Verilator 测试，不直接实现完整 test plan，也不覆盖 flush、replay、replacement 等后续内容。

当前目标很单纯：

- 只发送一个 `0x0` 的取指请求
- 在 testbench 里每周期观察 `refill_req_valid`
- 一旦观察到 `refill_req_valid == 1`，记录下 `refill_req_pc`
- 从这个时刻开始数 `6` 个周期
- 在第 6 个周期，给 ICache 一个**脉冲式** `refill_resp_valid`
- `refill_resp_pc` 使用刚才记录下来的地址
- `refill_resp_data` 用固定模式填满整条 cache line
- 然后观察 refill 完成后，ICache 是否能对原始请求产生正确输出

这是一个“最小闭环”的 miss/refill 测试。

它的价值不是覆盖面广，而是先把下面这条最核心链路跑通：

`请求 miss -> 发 refill_req -> 外部等待 6 周期 -> 回 refill_resp -> ICache DONE 输出`

---

## 对当前方案的一个关键澄清

你提到：

- 数据就用 `0xdeadbeef`
- 一直重复，直到填满 cacheline

这个理解我认为是对的，但这里需要明确一下：

### 不是“多拍把 cache line 一点点填满”

按照当前 `doc/icache.md` 和 `rtl/frontend/icache.sv` 的接口定义，`refill_resp_data` 是：

- 一次 response
- 携带**整条 cache line**
- 宽度是 `ICACHE_BLOCK_SIZE_BYTES * 8`

也就是说，当前接口不是 bank-by-bank 的多拍返回，而是：

- `refill_resp_valid` 拉高一拍
- 这一拍里一次性给完整 line data

所以“直到填满 cacheline”在当前接口语义下，应该理解为：

- 在 testbench 里构造一个完整的 cache line 数据
- 这个 line 的每个 32-bit word 都填 `0xdeadbeef`
- 然后在 **一个 pulse response** 里整条送回

如果当前配置是：

- `FETCH_BYTES = 16`
- `ICACHE_BLOCK_SIZE_BYTES = 64`

那么：

- 一条 line = 64B = 512bit
- 一个 32-bit word = 4B
- 一条 line 一共 `64 / 4 = 16` 个 word

所以 testbench 要生成：

- 16 个连续的 `0xdeadbeef`
- 拼成一个 512-bit `refill_resp_data`

也就是逻辑上的：

```text
refill_resp_data = {
  0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef,
  0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef,
  0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef,
  0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef
}
```

---

## 这个基础测试建议怎么做

### Step 1，复位完成后，只发一个 `s0_pc = 0x0`

输入：

- `s0_valid = 1`
- `s0_pc = 64'h0`

然后只让这个请求打一拍，后续拉低 `s0_valid`。

这样做最干净，避免把“同一个请求重复打很多拍”和“真正的单次 miss 请求”混在一起。

### Step 2，在 testbench 里死循环轮询 `refill_req_valid`

每个周期检查一次：

- 如果 `refill_req_valid == 0`，继续等
- 如果 `refill_req_valid == 1`：
  - 记录 `refill_req_pc`
  - assert 这个地址必须是 line-aligned
  - assert 这个地址对当前 case 必须等于 `0x0`

因为输入请求就是 `0x0`，而且 line-aligned 之后还是 `0x0`，所以这是最直接的检查。

### Step 3，从观察到 request 的那一拍开始，等待 6 个周期

这里建议把“6 个周期”定义清楚：

- 在检测到 `refill_req_valid == 1` 的周期记为 `T0`
- 然后等待 `T1 ~ T6`
- 在 `T6` 这一拍驱动 `refill_resp_valid = 1`

这个等待逻辑纯粹由 testbench 控制，相当于模拟下一级 memory 的固定返回延迟。

### Step 4，在第 6 个周期回一个 pulse response

response 内容：

- `refill_resp_valid = 1`（仅一拍）
- `refill_resp_pc = recorded_refill_req_pc`
- `refill_resp_error = 0`
- `refill_resp_data = full_cacheline_deadbeef_pattern`

下一拍：

- `refill_resp_valid = 0`

这就符合当前文档定义的 pulse response 协议。

### Step 5，观察 ICache 输出

按当前 RTL 语义，response 收到后会进入 `DONE`，然后给出：

- `out_valid = 1`
- `out_pc = miss_pc = 0x0`
- `out_error = 0`
- `out_data = refill line 中 miss_bank 对应的 FETCH_BYTES 数据`

当前 `0x0` 对应：

- line base = `0x0`
- bank index = 0

而我们整条 line 都填了 `0xdeadbeef`，因此 bank0 对应的 16B 数据也会是：

```text
{0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef}
```

也就是 128-bit 的全 `deadbeef` 重复模式。

---

## 这个最小测试里，我建议现在就加哪些 assert

我觉得这个阶段完全可以加 assert，而且应该加。因为这个 case 很小，assert 成本低、收益高。

### 1. 请求地址检查

当 `refill_req_valid == 1` 时：

- assert `refill_req_pc == 64'h0`
- assert `refill_req_pc % ICACHE_BLOCK_SIZE_BYTES == 0`

目的：

- 验证 miss 请求被对齐到了 line base
- 防止后续 line address 计算错位

### 2. request pulse 宽度检查

- assert `refill_req_valid` 只持续 1 拍

也就是：

- 当前拍看到 `refill_req_valid == 1`
- 下一拍必须回到 `0`

目的：

- 验证当前 pulse 协议没有被错误实现成 level 信号

### 3. response 之前不能提前出结果

在 `refill_resp_valid` 打回来之前：

- assert 不应该出现“这次 miss 的最终正确输出”

更保守一点，可以先检查：

- 在等待 response 的阶段，不应该出现 `out_valid && out_pc == 0x0 && out_error == 0`

目的：

- 防止 DUT 在 refill 未完成前错误地提前吐数据

### 4. response 后 DONE 输出检查

在 response 生效并进入 DONE 后：

- assert `out_valid == 1`
- assert `out_pc == 64'h0`
- assert `out_error == 0`
- assert `out_data` 等于 4 个 `0xdeadbeef`

目的：

- 这是这个 case 最核心的功能检查

### 5. refill 成功后的再次访问命中检查

这个我强烈建议顺手加上，虽然它只比“最小闭环”多半步，但性价比很高。

做法：

- 第一次 miss/refill 完成后
- 再次发送 `s0_pc = 0x0`
- 检查这次应该直接命中

可以检查：

- `out_valid == 1`
- `out_hit == 1`
- `out_pc == 0x0`
- `out_error == 0`
- `out_data` 仍然是 4 个 `0xdeadbeef`
- 并且不应再次出现 `refill_req_valid`

这个检查的意义很大，因为它不仅验证 DONE 输出，还顺手验证了：

- tag 写回成功
- data bank 写回成功
- valid 位置位成功

如果只检查 DONE 输出，其实还不能完全证明 line 真写进 cache 了。

---

## 关于“只加 debug 端口”的理解

你说“只加 debug 端口”，我理解你的意思更像是：

- 现在先不要上复杂 testbench 架构
- 也不要一次把大测试计划全实现
- 先做一个最基本的 case
- 必要时为了观察方便，可以给 RTL 多暴露一点 debug 信息

我赞同这个思路。

不过对这个基础 case 来说，我觉得**未必必须先加新的 debug 端口**，因为现有可观察信号已经足够支撑第一版：

- `refill_req_valid`
- `refill_req_pc`
- `refill_resp_valid`
- `out_valid`
- `out_hit`
- `out_pc`
- `out_data`
- `out_error`

这些已经能验证最基本闭环。

如果你想加 debug 端口，我认为最有价值的是下面两个，而不是一上来加很多：

### 候选 debug 1：当前 miss 的 victim way

这样未来验证 replacement 会方便。

### 候选 debug 2：当前 refill 是否被 discard

这样未来验证 flush during WAIT/REQ 会方便。

但对这次“0x0 单请求 + 固定 6 周期回包”的最基础 case 来说，这两个都不是硬需求。

所以我的建议是：

- **这版讨论文档先不把“新增 debug 端口”当成前提条件**
- 先基于现有接口把基础闭环讨论清楚
- 如果你后面觉得观察起来还是不够，再补最少量 debug

---

## 我建议咱们这次先达成的测试定义

如果把这个最小 case 定义成一句话，我建议写成：

> 复位后仅发送一次 `s0_pc = 0x0` 的取指请求；testbench 轮询 `refill_req_valid`，捕获其 request 地址后等待固定 6 周期，再以单拍 pulse 返回对应 line-aligned `refill_resp_pc` 和整条由 `0xdeadbeef` 填满的 cache line；随后检查 ICache 在 DONE 阶段对原 miss 输出正确的 `out_valid/out_pc/out_data/out_error`，并可选地再次访问 `0x0` 验证 refill 后 hit。

---

## 我个人建议

我建议这个“最基本测试”最终分成 **两个小层次**，不要只停在第一层。

### 层次 A，最小闭环

只检查：

- miss 触发 request
- 6 周期后 response
- DONE 输出正确

### 层次 B，闭环后再访问一次 0x0

再补检查：

- 第二次访问命中
- 不再发 request

原因很简单：

- 层次 A 只能证明“response 回来后当前拍输出像是对的”
- 层次 B 才真正证明“cache line 真的写进去了”

我更推荐直接做到层次 B，因为多不了多少工作，但验证力度强很多。

---

## 当前讨论结论

我建议我们先按下面这版共识推进：

1. **请求只发一次**：`s0_valid` 对 `s0_pc=0x0` 打一拍。
2. **testbench 每周期轮询 `refill_req_valid`**。
3. **检测到 request 后记录 `refill_req_pc`**，并 assert 它等于 line-aligned 的 `0x0`。
4. **固定等待 6 个周期**。
5. **response 只打一拍 pulse**。
6. **response 返回整条 cache line**，不是分多拍返回 bank。
7. **整条 line 的每个 32-bit word 都填 `0xdeadbeef`**。
8. **至少检查 DONE 输出**：`out_valid/out_pc/out_data/out_error`。
9. **强烈建议再检查一次 0x0 重访命中**。
10. **这一版先不强依赖新增 debug 端口**，除非你觉得观测仍然不够。

---

## 下一步

如果你认可这套定义，下一步可以做两件事之一：

1. 我再补一版更短的“实现清单文档”，把这个 case 细化成 testbench 编码步骤。
2. 你拍板后，我直接去改 `sim/icache/tb_icache.cpp`，实现这个最基础 case。