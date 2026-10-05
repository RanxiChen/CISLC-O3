# O3-T03 实现与验证报告

实现中；当前尚未完成 Alan 验收，不宣称 L5 通过。

已按任务书直接实现，没有阶段一 spec。跨模块合同新增：ROB 的完整串行队头元数据、
CSR 源寄存器/指令/实际后继、执行异常；RAT/free-list/SQ 的提交边界 flush，
CSR 的退休增量/实际 WARL 写值；trace 的 CSR/trap 字段。

实现细节：CSR 一拍执行、下一拍退休，队头时独占 PRF 第 0 读写口；
不增加全流水 CSR IQ。misa 按 Breeze 保持常量 WARL（软件写入忽略），
只读地址编码 CSR 的写入非法。mtvec 支持 0/1，保留模式收敛 direct；mepc 低两位清零。
mie 保留 MSIE/MTIE/MEIE（0x888），mip 为零。计数器在真实退休时增长，trap 不增长。

Store 在 SQ 保存地址/数据，但以只读 DCache 请求确认访问成功后才标记 ROB complete；
此探测不改缓存数据，不提前产生存储副作用。提交后 drain 仍按原 B05 通路执行。
LSU 全局取消保留单在途请求的所有权直到返回；新 load/probe 在其返回前回压，
迟到结果不写 PRF/ROB。已提交 SQ 项跨 trap 保留并继续 drain。

L5 顺序 BPU 对已知系统目标直接恢复取指，不发分支预测快照恢复；
完整预测器提交上下文在 L7 集成。FENCE.I 实现只包含 SQ drain 与 ICache idle 后全失效，
不支持自修改代码；完整 L1D clean 序列待 L8。WFI 按 NOP，外部 irq 本级 tie-off。

本次没有改变 Dxx/Bxx 决策，没有删除或放宽现有测试、断言或期望。
验收命令、SHA、日志与后续 bug 记录在实测后追加。

## Bug 1：PRF/ROB 载荷的 unpacked array 方向不匹配

首版 `8cd9fa9` 在 Alan 既有 rv64i 固定门禁 order=2 首差异 rd_wdata：
ADDIW x3,x1,1 的 DUT=1、Spike=0xffffffff80000001。日志
`/home/chen/FUN/CISLC-O3-runs/20261006-o3t03/trial-8cd9fa9/fixed.log`。
根因是新中间 PRF 数组声明为 [N]（升序），原模块端口为 [N-1:0]（降序），
SV 在整个 unpacked array 连接时按位置映射，使 scalar 下标读取的读写口颠倒。
新 ROB 元信息数组有相同问题。修正两端方向，commit_i 对齐 ROB 的 lane 方向。
缩减到三条静态指令 `tests/prf_lane_order.hex` 并加入 run-spike-all 的独立门禁；
没有改既有 rv64i 期望值。属于本次实现引入的 bug，不是 O3-T02 基线缺陷。
提交后 Alan 对照/回归继续，当前修复后功能未验证。

## 开发轮次补充

`0965f1c23e06d38af3324d14e51502bbe30ca1c6` Alan 重新 build 成功，
固定门禁 7/7（原 6 项加最小 PRF 复现）0 差异；日志
`/home/chen/FUN/CISLC-O3-runs/20261006-o3t03/trial-0965f1c/fixed.log`。
同 SHA 新增三个合同套件各通过；M 模式固定程序在 order=16 失败：
cycle 影子 CSR 未在 Spike ISA 字符串中启用 Zicntr。修正参考配置为
rv64i_zicsr_zifencei_zicntr，不改 DUT 或期望；平台 reset mtvec 初始化为 0x200。
ACT4 L5 初始配置使用了 schema 不接受的 MTVEC_ILLEGAL_WRITE_BEHAVIOR 枚举；
按现有 WARL 行为声明为 custom，未修改已有 I target 或上游测试体。

新增 riscv-tests L5 启动/邮箱包装只避开上游默认 env 中本级未实现的 S/U、PMP、
委托初始化，不改 upstream isa/rv64mi 测试体/断言/期望。使用官方源
`bcffa2b3188b040c611f90dc0b6e422f54775a09`；目标 csr/mcsr/illegal/sbreak/scall。
ma_addr 依赖非对齐访存策略，按任务书留 L8；本级不宣称该项通过。
