# CISLC-O3 微架构设计基线

本目录是 CISLC-O3 微架构**决策**的权威来源。RTL 注释、`rtl/common/o3_cfg_pkg.sv`
和 `doc/LOOP.md` 中引用的 `Dxx` / `Bxx` 编号均指这里。

| 文件 | 内容 |
|---|---|
| [`CISLC-O3-FRONTEND-DESIGN-BASELINE.md`](CISLC-O3-FRONTEND-DESIGN-BASELINE.md) | 前端决策 D01–D29：预测、FTQ、ICache、恢复、系统同步 |
| [`CISLC-O3-BACKEND-DESIGN-BASELINE.md`](CISLC-O3-BACKEND-DESIGN-BASELINE.md) | 后端决策 B01–B47：重命名、发射执行、访存、缓存层次、提交/异常/CSR、Linux 平台；B42–B47 为 2026-10-05 v1 实施计划决定 |

## 规则

- 这两份文档记录的是"为什么这么定"，**只有用户可以修改**决策内容。
- agent 实现时可以"闭环简化"（推迟实现某机制），但不得改变决策；
  需要改变决策时停下来问用户（见 `agent.md` 第 1.2 节）。
- 文档中的"已定 / 暂定 / 待定"与"RTL 已实现"无关；实现进度只看 `doc/LOOP.md`。
- 文中出现的源码快照、行号、提交哈希是记录当时的只读核对结果，可能已过时。

## 来源

2026-10-03 从 Flow 仓库 `docs/cross-project/` 迁入（迁入时的内容即当时最新版，
2026-10-02 更新）。此后以本目录为准。

配套的建模与 RTL 协同演进记录（`CISLC-O3-MODELING-AND-RTL-COEVOLUTION.md`）
按其自身约定仅在本地维护，不进入本仓库。
