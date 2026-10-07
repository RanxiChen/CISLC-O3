# O3-T07：L9 分步任务书（T07a～T07b）

唯一实施依据：[L9 spec](../spec/l9-fpu-spec.md)（2026-10-07 审核修订版，W1～W12）。本文只规定分步顺序与每步测试范围，不新增任何行为。

**本次授权仅为两份文档的修订，不开始 RTL、不初始化 submodule、不运行仿真、不提交。以下流程及末尾提示供后续获授权的实施任务使用。**

## 共同规则（每一步都适用）

- 遇到 spec 未覆盖的架构行为、互相矛盾的合同或必须改变 Dxx/Bxx 的机制：停下报告具体冲突，不自行补设计；不改 spec 与 `doc/design/`。实现细节（字段编码、文件组织、槽数、测试脚本等 spec 允许选择的项）自行决定并在报告写明，不反复询问（agent.md 1.2）。
- 只改 spec 第 0 节允许的文件；不跑 Spike、ACT4、访存类 cocotb（`dcache`、`l2_cache`、`load_queue`、`store_queue`、`load_store_unit`、`load_store_unit_l5`）；不综合。
- 测试在 Alan 上运行（`source /home/chen/miniforge3/bin/activate cislc-o3`，Verilator 5.050、cocotb 2.1.0），
  使用独立运行目录 `/home/chen/FUN/CISLC-O3-runs/<日期>-t07<x>-<sha>/`，不改 Alan 原开发树；开跑前核实工具版本、checkout SHA 与工作树。GitHub 访问按 agent.md 3.1 走反向代理，禁止 Git bundle。
- **submodule 固定版本**：`third_party/cvfpu` URL 为 `https://github.com/RanxiChen/cvfpu.git`，gitlink 为 `1b220f3bc89df99e246b72e3574a3a533cf87653`；必需嵌套依赖 `src/common_cells` 为 `6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea`。在本地/Alan 各 checkout 按父提交 gitlink 初始化；不复制源码、不用 `update --remote`、不改子模块源码。初始化命令与文件清单记入父仓库 `third_party/CVFPU.md`。不要求初始化本级未使用的 MVP 除法库或 flexfloat 测试库。
- **开发提交与验收分开**：本地编辑 → Alan 开发检查（含 lint；本地仅阅读/编辑/脚本准备）→ lint 通过后开发提交/push → Alan 在该精确 SHA 上运行门禁。为把首次未提交的改动送到独立 Alan 开发目录做 lint，可用 SSH/rsync 同步允许列表内的文件，保留来源记录；submodule 仍从 GitHub 按固定 gitlink 初始化，不能复制其源码。开发目录检查不算最终验收证据。
- 门禁（spec 第 12 节）：
  - 本步实际接入的新合同 cocotb、L7a/L7b 全部 cocotb、受影响的非访存 cocotb，及本步 `run-l9-fp` 必须通过；回归包括
    `make -C sim/o3 run-smoke`、`run-rv64i-instructions`、`run-l3-branch-dense`、`run-l7-predict`、`run-l7b-rvc`
    （整核回归带 `SPIKE_ARGS=+L7_CHECK`，不带 `--spike`），以及 `scripts/lint.sh` 0 errors。
  - **阶段验收绑定同一个最终推送的 RTL/测试 SHA**：在独立目录重建并完成上述门禁，记录完整 SHA、cwd、命令、exit code、用例数与日志目录。修复改变 RTL/测试后，最终候选 SHA 的完整门禁重新运行；旧 SHA 的通过证据不能拼成新 SHA 的验收。
  - 正确性失败修不好：停下报告失败用例、SHA、日志与复现命令，不宣告本步完成、不进入下一步。保留开发提交及失败证据，不削弱测试/断言/期望，不把历史基线失败说成本次通过，也不擅自扩大范围修后级问题。
- **T07a、T07b 连续执行**：未来实施任务获授权后，T07a 最终推送 SHA 在 Alan 通过门禁，更新阶段状态后直接进入 T07b，不等再次确认；只有上述正确性/设计合同阻塞时停下。两步合写 `doc/tasks/O3-T07-report.md`，T07a 记录“数据通路子集通过”，不把它记为 L9 或完整 F/D 完成。
- 精简流程：开发迭代只重跑受影响的套件；每个最终候选 SHA 跑一次完整门禁。报告/状态等纯文档提交另行标明对应已验证的代码 SHA，不把文档 SHA 冒充重新运行过的代码 SHA。
- 提交信息：`feat(backend|system|frontend|third_party): ...`，可多次开发提交。CVFPU submodule 接入（含 `.gitmodules`、gitlink、来源记录/文件清单与兼容豁免）单独一个提交，提交前确认 lint 0 errors。

## T07a：FP 数据通路骨架 + MISC/CONV FU + 浮点访存

内容：
- W1：添加固定版本 CVFPU submodule、初始化必需 common_cells，记录 `third_party/CVFPU.md`，加入 `rtl/rtl.f` 与限定路径/规则的 lint 豁免；按共同规则单独提交。首次导入的 lint 只证明解析，接入 FU 后仍需实际功能门禁。
- 第 2 节（CSR、mstatus.FS/SD、Rename 入口检查、退休合并），**misa 保持 RV64IMC，不设 F/D**；FS/frm/fflags 的复位值按 spec 2.2。
- 第 3 节译码（FMA 与 FDIVSQRT 类暂译非法）。
- 第 4 节（FP 重命名域，沿用单拍重命名）；第 5 节（分域唤醒、FP IQ、读口、FSW/FSD 数据、MISC/CONV RegRead 与两个请求接受边界）。
- 第 6 节共同结构，实现 `fpu_misc_fu`、`fpu_conv_fu`（含 FMV 旁路、共同结果保持槽、侧表寿命及同拍取消/全局 flush）；第 7、8 节相关路径全部接通。
- FMA/DIVSQRT 不实例化，FP IQ 不给它们候选；固定写回源数组的未接入项显式 tie-off 并说明阶段。T07a 不宣称完整 RV64FD。
- 第 10 节中与上述相关的类型、端口与配置。

测试：spec 第 12 节的译码、CSR、重命名、IQ/PRF 读口、PRF/ready、backend 控制、分域写回、ROB 与退休合并中已经接通的合同；
`fpu_fu` 的共同结构及 MISC/CONV 部分，覆盖 FMV/CONV 输出竞争、背压、同拍误预测、全局 flush 后迟到结果丢弃。
整核命令 `make -C sim/o3 run-l9-fp L9_T07A=1`（映射 `-DT07A`）：spec 12.1 的 1、2 不含 RVC 的部分、3、5 的 **sNaN 比较 NV**、6 及 7 的 MISC/CONV 恢复子集；不执行 FMA、除法、开方或 FP RVC，不检查除法/开方的 0x19。
程序主体 `.option norvc`，避免编译器/汇编器自动生成 T07a 尚未支持的 FP RVC；阶段 misa 断言必须匹配 RV64IMC。全部共同回归。

## T07b：FMA×2、DIVSQRT、浮点 RVC、完整整核程序

内容：
- 实现 `fpu_fma_fu`（例化两个）与 `fpu_divsqrt_fu`；译码放开 FMA 与 FDIVSQRT 类。
- 第 9 节：浮点 RVC 四条与 C.LUI 修正。
- 第 2.2 节：misa 加 F/D；FMA/DIVSQRT 的 RegRead、写回源与取消路径接通。
- 完整 `l9_fp.S`（12.1 全部 7 项）与 `run-l9-fp`。
- 更新 `doc/LOOP.md`：L9 一行与相关模块行（含 W5“FP 提前唤醒推迟”的闭环简化说明）。

测试：`fpu_fu` 全部；`rvc_expander` 新增项；IQ 两 FMA 同拍接纳、双 FP 写回及各自 fflags；T07a 已接入机制的全部用例；
`make -C sim/o3 run-l9-fp`（完整，默认不定义 T07A）与全部回归。阶段 misa 断言改为 spec 明确要求的 RV64IMFDC，保留其余既有期望；不把 `L9_T07A=1` 程序的过渡 misa 断言直接套到 T07b RTL，也不靠该宏裁剪 RTL/FU。
最终结论仅为 L9 定向浮点闭环通过；Spike F/D 比对、MRET 返回路径、综合/PPA/FPGA 均标“未运行”。

---

## 交给 Codex 的提示（复制使用）

```
在 /home/chen/work/CISLC-O3（分支 feat/L1-closure，RTL 基线 97e8d2903b7765005ef4e0ce38bb7191e4a5703b，
加本次审核修订版 spec/任务书；开始前核实实际 HEAD 与工作树）实施 L9 F/D 浮点。
本提示仅在用户另行授权 RTL 实施后使用；文档修订任务不授权执行以下步骤。

唯一依据：doc/spec/l9-fpu-spec.md（2026-10-07 审核修订版，W1～W12）。分步与门禁：doc/tasks/O3-T07-l9-tasks.md。
先完整读这两份文件、spec 第 1 节列出的源码位置，以及：
  - Flow 仓库 ~/leisure/flow 的固定提交 7dfa75c4eca1bd68cd82780508cc8eb84659e835（不依赖工作树 HEAD）：
    design/src/main/resources/vsrc/fpnew/FlowFpnewWrapper.sv、cvfpu-files.f；
  - CVFPU fork https://github.com/RanxiChen/cvfpu.git，固定提交
    1b220f3bc89df99e246b72e3574a3a533cf87653 的 fpnew_top.sv 与 fpnew_opgroup_block.sv；
    必需嵌套 common_cells 固定 6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea；
  - Breeze 译码映射 design/src/main/scala/fpu/BreezeFp.scala:74-227、backend/BreezeBackend.scala:341-350、
    frontend/BreezeCompressedDecoder.scala（浮点 RVC）。
再动手。

要求：
1. 按 T07a → T07b 顺序做；开发提交/push 用于 Alan 验证，每步最终推送的代码 SHA 门禁通过后
   才验收并进入下一步，不等再次确认。CVFPU 用 submodule 接入、固定 gitlink，单独提交；不复制源码。
2. 架构行为或设计合同不清/冲突：停下报告，不自行改设计；实现细节按 spec 自选并记录。
   不改 doc/spec、doc/design 或 submodule 源码。
3. 只改 spec 第 0 节允许的文件。
4. lint/仿真在 Alan 独立运行目录跑；按同一 gitlink 初始化必需 submodule，GitHub 按 agent.md 走
   反向代理，禁止 Git bundle。不跑 Spike/ACT4/访存类 cocotb，不综合。
5. 正确性门禁修不好：保留开发提交和失败证据，停下报告，不验收、不进入下一步；不削弱测试。
6. 最后写 doc/tasks/O3-T07-report.md：提交号、每条命令与 exit code、用例数、日志目录、失败与修复记录、
   实现时自选的细节（槽数、字段编码等）、未做项。同时更新 doc/LOOP.md 中 L9 一行和相关模块行的状态。
7. T07a 用 run-l9-fp L9_T07A=1，只含 MISC/CONV/FP访存，NV 用 sNaN 比较，misa 不设 F/D；
   T07b 默认完整程序、开放 FMA/DIVSQRT/FP RVC 并设 F/D。两步程序都避开已知 MRET 问题。
8. 严格实现 spec 的入口异常撤销、双发射/整数读口授权、RegRead→FU 握手、结果保持、侧表寿命、
   同拍取消/全局 flush 过滤及退休 flags/Dirty；每个新增合同一个简单定向用例。
```
