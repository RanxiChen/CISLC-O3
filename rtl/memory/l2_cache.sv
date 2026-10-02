/**
 * L2 cache —— L1I/L1D 下级 inclusive 缓存、DMA 行协调入口、DDR AXI 主口
 *
 * 已定结构（B41，2026-10-02 用户确认；B03/B08 的既有定位保持）：
 * - L2 已纳入首版，不是可选模块；单 hart，只处理一个 hart 与 SD DMA 的必要一致性，不引入
 *   多核 MESI/MOESI 目录。
 * - inclusive：覆盖 L1I 与 L1D。L1 中任何有效行在 L2 中必有驻留项或同行在途事务。
 * - 组相联；tree-PLRU 替换（每 set ways-1 位；命中与安装时更新；选 victim 时跳过正在回收、在途或
 *   受保护的 way；路数须为 2 的幂）。
 * - 淘汰（inclusive 回收，l2_recall_ctrl）：保护目标行 → 定向失效两个 L1（首版每次都探测两个，
 *   不建精确驻留目录）→ L1D 脏副本先交回最新数据再确认 → 协调在途回填，防止旧响应重新安装 →
 *   收齐确认、接管最新数据并为必要写回提供可靠保存位置后才复用 way。inclusive 不代表 L2 数据
 *   始终最新。容量替换不清 LR/SC reservation。
 * - 资源：启动回收前预留接收/写回所需资源；探测应答不依赖普通 miss 的空闲 MSHR；资源不足推迟新
 *   回收，不堵旧事务完成。
 * - 同一物理行由统一行事务状态确定顺序（兼容读 miss 合并）：回填、L1D 写回、淘汰、DMA 不能各自
 *   独立修改同行状态；不同行继续并行。
 * - 完整 L1D 行写回不需要先读 DDR；正常情况下应命中 L2 项或同行在途事务；正在回收时并入回收
 *   事务，不重新分配；既无驻留项又无在途事务时暴露包含关系错误（inclusion_err_o），不能用自动
 *   重新分配掩盖。
 * - 下级不能静默成为全部访存的全局串行瓶颈：独立命中继续服务、多个下级请求在途是设计目标。
 * - DMA 不能绕过仍可能持有最新数据的 L2 直接读旧 DDR；部分行写用最新数据保留未覆盖字节（B08）。
 *   内含 dma_line_coord：一笔 DMA 行协调事务在途，探测唯一 L1D；DMA 探测与回收探测在本模块内
 *   仲裁进入 L1D 的同一维护入口（l1d_probe_*），二者均不得被对方永久饥饿。
 * - 写回 DDR 失败（BRESP 错误等）按 B39 上报 fatal，不按成功释放，维护/DMA 不虚假完成。
 * - 曾讨论让 L2 跟踪 L1I 驻留、绕过 L1 查询，未选为第一版（前端 11.3 节）。
 *
 * 未冻结（不能当作已决定）：容量、路数、bank、line 大小、MSHR/回收槽/写回缓冲数、AXI 宽度/ID/
 * 突发、与 L1 line 大小不同时的处理、DDR 控制器接口（KCU105 MIG 等）、具体流水拍数；
 * “L2 整行收齐、无错误并安装后再交付 L1，暂不 early restart”仍只是建议，未确认。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 * 现有 rtl/memory/axi_master.sv 是单笔在途冒烟主口，不是本模块的实现。
 *
 * 逐周期说明（目标）：
 * - 周期 N：L1/DMA 请求进入 L2 主流水查 tag，同行统一事务状态决定命中/合并/等待/新分配。
 * - miss 分配：tree-PLRU 选 victim；victim 有效时先启动回收（需资源预留），回收完成前该 way 不复用。
 * - 回收与 DMA 探测按各自身份收齐应答后推进；写回 DDR 在 B 通道确认后才释放写回缓冲。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module l2_cache
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int AXI_ID_W   = CFG.l2.axi_id_bits,
    localparam int AXI_DATA_W = CFG.l2.axi_data_bits
) (
    input  logic            clk,
    input  logic            rst,

    // L1I
    input  logic            l1i_req_valid_i,
    output logic            l1i_req_ready_o,
    input  l2_req_t         l1i_req_i,
    output l2_resp_t        l1i_resp_o,
    input  logic            l1i_resp_ready_i,

    // L1D 回填与写回
    input  logic            l1d_req_valid_i,
    output logic            l1d_req_ready_o,
    input  l2_req_t         l1d_req_i,
    output l2_resp_t        l1d_resp_o,
    input  logic            l1d_resp_ready_i,
    input  logic            l1d_wb_valid_i,
    output logic            l1d_wb_ready_o,
    input  paddr_t          l1d_wb_line_paddr_i,
    input  logic [DC_LINE_BYTES*8-1:0] l1d_wb_data_i,
    output logic            l1d_wb_error_o,       // 写回被拒（包含关系错误等，B39/B41）

    // L1I inclusive 回收的定向失效（B41）
    output logic            l1i_recall_valid_o,
    input  logic            l1i_recall_ready_i,
    output l1_recall_req_t  l1i_recall_o,
    input  l1i_recall_resp_t l1i_recall_resp_i,

    // L1D 维护探测：DMA 行协调（B08）与 inclusive 回收（B41）共用
    output logic            l1d_probe_valid_o,
    input  logic            l1d_probe_ready_i,
    output dc_probe_req_t   l1d_probe_o,
    input  dc_probe_resp_t  l1d_probe_resp_i,

    // SD DMA 行事务
    input  logic            dma_req_valid_i,
    output logic            dma_req_ready_o,
    input  dma_req_t        dma_req_i,
    output dma_resp_t       dma_resp_o,

    // DDR AXI4 主口（信号组按 AXI4，宽度待定）
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    output logic [AXI_ID_W-1:0]   m_axi_awid,
    output logic [PADDR_W-1:0]    m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    output logic [AXI_DATA_W-1:0] m_axi_wdata,
    output logic [AXI_DATA_W/8-1:0] m_axi_wstrb,
    output logic                  m_axi_wlast,
    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready,
    input  logic [AXI_ID_W-1:0]   m_axi_bid,
    input  logic [1:0]            m_axi_bresp,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,
    output logic [AXI_ID_W-1:0]   m_axi_arid,
    output logic [PADDR_W-1:0]    m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,
    input  logic [AXI_ID_W-1:0]   m_axi_rid,
    input  logic [AXI_DATA_W-1:0] m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast,

    output logic            inclusion_err_o,      // B41：L1D 写回既无驻留项又无同行在途事务
    output fatal_evt_t      fatal_o,              // B39：写回 DDR 失败
    output be_perf_t        perf_o
);
    // 未实现：L2 阵列、tree-PLRU、统一行事务状态、MSHR、AXI 引擎；
    // 内部应例化 dma_line_coord、l2_recall_ctrl，以及 DMA/回收探测到 l1d_probe_* 的仲裁。
endmodule
