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
