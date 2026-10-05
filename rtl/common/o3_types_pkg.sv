/**
 * O3 推导类型包 —— 从 O3_CFG 推导位宽与跨模块数据结构
 *
 * 规则：
 * - 本包不写任何可调数值，只从 `o3_cfg_pkg::O3_CFG` 推导（ISA 常量 XLEN/ILEN、
 *   异常 cause 编码来自 `o3_isa_pkg`，它们由规范固定，不是可调参数）。
 * - 依赖方向：o3_cfg_pkg、o3_isa_pkg ← 本包 ← o3_pkg（后端旧类型）。本包不得 import o3_pkg。
 * - 这里定义的是跨模块的“合同”结构。模块内部的表项、状态寄存器不放在这里。
 * - 握手通道约定：有 ready 的通道用独立的 `*_valid / *_ready` 信号，struct 内不放
 *   valid；没有 ready 的广播（解析、提交、取消、重定向）在 struct 内带 `valid`。
 * - 字段“逻辑内容”来自设计基线；具体编码、位宽与 SRAM 拆分仍待实现时确定，
 *   标注“编码待定”的字段不代表已经冻结。
 *
 * 当前范围：core 公共类型、前端合同、后端新增合同（寄存器域、FU 请求身份、M/F/A 操作、
 * DCache/PTW/DMA、CSR/trap、提交信息）。后端旧流水载荷（decoded_uop_t 等）仍在 `o3_pkg`，
 * 通过本包的 uop_ext_t / rename_ext_t 扩展字段承接新机制。
 *
 * O3_CFG 已填入首版暂定规模；类型包可单独静态检查，不表示数据通路已连通。
 */
package o3_types_pkg;
    import o3_cfg_pkg::*;
    // Explicit imports make wildcard re-export portable to Vivado 2022.2.
    import o3_isa_pkg::XLEN;
    import o3_isa_pkg::ILEN;
    import o3_isa_pkg::REG_ADDR_WIDTH;
    import o3_isa_pkg::NUM_ARCH_REGS;
    import o3_isa_pkg::FFLAGS_W;
    import o3_isa_pkg::FRM_W;
    import o3_isa_pkg::CSR_ADDR_W;
    import o3_isa_pkg::EXCEPTION_CAUSE_INST_ADDR_MISALIGNED;
    import o3_isa_pkg::EXCEPTION_CAUSE_INST_ACCESS_FAULT;
    import o3_isa_pkg::EXCEPTION_CAUSE_ILLEGAL_INSTRUCTION;
    import o3_isa_pkg::EXCEPTION_CAUSE_BREAKPOINT;
    import o3_isa_pkg::EXCEPTION_CAUSE_LOAD_ADDR_MISALIGNED;
    import o3_isa_pkg::EXCEPTION_CAUSE_LOAD_ACCESS_FAULT;
    import o3_isa_pkg::EXCEPTION_CAUSE_STORE_ADDR_MISALIGNED;
    import o3_isa_pkg::EXCEPTION_CAUSE_STORE_ACCESS_FAULT;
    import o3_isa_pkg::EXCEPTION_CAUSE_ECALL_U;
    import o3_isa_pkg::EXCEPTION_CAUSE_ECALL_S;
    import o3_isa_pkg::EXCEPTION_CAUSE_ECALL_M;
    import o3_isa_pkg::EXCEPTION_CAUSE_INST_PAGE_FAULT;
    import o3_isa_pkg::EXCEPTION_CAUSE_LOAD_PAGE_FAULT;
    import o3_isa_pkg::EXCEPTION_CAUSE_STORE_PAGE_FAULT;
    import o3_isa_pkg::exception_cause_t;
    // ISA 常量（XLEN/ILEN、异常 cause 编码等）随本包对外可见。
    // 下游模块只 import o3_types_pkg::* 时也能拿到这些由规范固定的常量，
    // 与 o3_pkg 的既有做法一致（见 o3_pkg.sv 的 export o3_isa_pkg::*）。
    export o3_isa_pkg::*;

    // ============================================================
    // 推导常量
    // ============================================================
    localparam int VADDR_W       = O3_CFG.core.vaddr_bits;
    localparam int PADDR_W       = O3_CFG.core.paddr_bits;
    localparam int ASID_W        = O3_CFG.core.asid_bits;
    localparam int XLATE_EPOCH_W = O3_CFG.core.xlate_epoch_bits;
    localparam int COMMIT_W      = O3_CFG.core.commit_width;
    localparam int PMP_N         = O3_CFG.core.pmp_entries;
    localparam int PAGE_OFFSET_W = 12;                         // Sv39 基本页 4KiB（规范固定）
    localparam int VPN_W         = VADDR_W - PAGE_OFFSET_W;
    localparam int PPN_W         = PADDR_W - PAGE_OFFSET_W;

    localparam int REGION_BYTES  = O3_CFG.fe.fetch.region_bytes;
    localparam int REGION_SLOTS  = REGION_BYTES / 2;           // 半字槽位
    localparam int SLOT_W        = $clog2(REGION_SLOTS);
    localparam int DELIVER_W     = O3_CFG.fe.fetch.deliver_width;
    localparam int F0_SLOTS      = O3_CFG.fe.fetch.f0_slots;
    localparam int F1_W          = O3_CFG.fe.fetch.f1_width;

    localparam int FTQ_DEPTH     = O3_CFG.fe.ftq.depth;
    localparam int FTQ_IDX_W     = $clog2(FTQ_DEPTH);
    localparam int FTQ_GEN_W     = O3_CFG.fe.ftq.gen_bits;
    localparam int RQ_DEPTH      = O3_CFG.fe.fetch.return_queue_depth;
    localparam int RQ_IDX_W      = $clog2(RQ_DEPTH);

    localparam int HIST_EVENT_W  = O3_CFG.fe.tage.event_bits;
    localparam int HIST_WINDOW   = O3_CFG.fe.tage.event_window;
    localparam int HIST_PTR_W    = $clog2(HIST_WINDOW);
    localparam int TAGE_META_W   = O3_CFG.fe.tage.meta_bits;

    localparam int RAS_DEPTH     = O3_CFG.fe.ras.depth;
    localparam int RAS_PTR_W     = $clog2(RAS_DEPTH);
    localparam int RAS_CNT_W     = $clog2(RAS_DEPTH + 1);

    localparam int ICACHE_LINE_BYTES = O3_CFG.fe.icache.line_bytes;
    localparam int L2_BEAT_BYTES     = O3_CFG.fe.icache.refill_beat_bytes;
    localparam int L2_TXN_ID_W       = O3_CFG.fe.icache.l2_txn_id_bits;

    // 单个上下文全部折叠值 C 的总位宽：sum_i(n_i + 2*t_i - 1)（D22）。
    function automatic int hist_fold_total_bits();
        int total = 0;
        for (int i = 0; i < TAGE_TABLES; i++) begin
            total += O3_CFG.fe.tage.index_bits[i] + 2 * O3_CFG.fe.tage.tag_bits[i] - 1;
        end
        return total;
    endfunction
    localparam int HIST_FOLD_W = hist_fold_total_bits();

    // ============================================================
    // 地址、身份与槽位
    // ============================================================
    typedef logic [VADDR_W-1:0]      vaddr_t;
    typedef logic [PADDR_W-1:0]      paddr_t;
    typedef logic [ASID_W-1:0]       asid_t;
    typedef logic [XLATE_EPOCH_W-1:0] xlate_epoch_t;
    typedef logic [SLOT_W-1:0]       fetch_slot_t;     // PC[3:1]
    typedef logic [REGION_SLOTS-1:0] slot_mask_t;
    typedef logic [RQ_IDX_W-1:0]     rq_idx_t;

    // 动态 FTQ 身份：环形索引 + 代际。同一区域多次动态进入是不同身份（第 3.1 节）。
    // 年龄比较需结合 FTQ 最老项位置处理回绕（D24）；回绕安全条件待定。
    typedef struct packed {
        logic [FTQ_GEN_W-1:0] gen;
        logic [FTQ_IDX_W-1:0] idx;
    } ftq_id_t;

    // 控制流类型与 RAS 动作分开表达：call/return 由 x1/x5 提示决定 RAS 动作，
    // 可以是 JAL 或 JALR（第 6.2 节）。
    typedef enum logic [1:0] {
        CFI_NONE = 2'd0,
        CFI_BR   = 2'd1,
        CFI_JAL  = 2'd2,
        CFI_JALR = 2'd3
    } cfi_type_e;

    typedef enum logic [1:0] {
        RAS_NONE     = 2'd0,
        RAS_PUSH     = 2'd1,
        RAS_POP      = 2'd2,
        RAS_POP_PUSH = 2'd3
    } ras_action_e;

    // ============================================================
    // 预测历史与恢复上下文（D09/D22/D23，第 6.2 节）
    // ============================================================
    typedef logic [HIST_EVENT_W-1:0] hist_event_t;

    // 区域入口 E/C 完整快照（D23）。events 按年龄排列的逻辑 E，[0] 最新；
    // 若物理环形布局需要指针，由 branch_history 内部恢复到规范布局。
    typedef struct packed {
        logic [HIST_WINDOW-1:0][HIST_EVENT_W-1:0] events;
        logic [HIST_FOLD_W-1:0]                   folds;
    } hist_snapshot_t;

    // RAS 区域入口恢复记录 ras_before（D29，2026-10-02 替换原 undo log 标记）。
    // 每个 FTQ 区域在推测操作之前保存；恢复时写回 top_idx/count，并把非空栈的 top_addr
    // 写回 top_idx 位置。count==0 时 top_addr 不参与修复。只修复栈顶，有意接受深层污染。
    // 16 项时 top_idx 4 位、count 5 位（RAS_CNT_W 保留 count==DEPTH 的满栈状态）。
    typedef struct packed {
        logic [RAS_PTR_W-1:0]  top_idx;
        logic [RAS_CNT_W-1:0]  count;
        vaddr_t                top_addr;
    } ras_ckpt_t;

    // 训练用 TAGE 元数据（provider、alt、计数状态等），内容与宽度待定，先作不透明位。
    typedef logic [TAGE_META_W-1:0] tage_meta_t;

    // ============================================================
    // BPU 内部与 BPU→FTQ
    // ============================================================
    // 一个区域的预测结果。快预测在分配时给出，慢预测确认/覆盖时给出同格式结果。
    typedef struct packed {
        vaddr_t      region_base;     // PC & ~0xf
        fetch_slot_t entry_slot;      // 实际入口槽位（落点可在区域中间）
        slot_mask_t  br_mask;         // 预测的条件分支位置（预测信息，需预解码验证）
        slot_mask_t  jal_mask;        // 预测的直接无条件跳转位置
        logic        cfi_valid;       // 选中了一个控制流出口
        fetch_slot_t cfi_slot;        // 选中出口槽位；其后槽位不属于本次动态路径
        cfi_type_e   cfi_type;
        ras_action_e ras_action;
        logic        raw_pred_taken;  // TAGE/类型原始判断为 taken
        logic        target_missing;  // taken 但无匹配目标，沿顺序路径（第 4.3 节）
        vaddr_t      cfi_target;
        vaddr_t      next_pc;         // 实际采用的下一区域入口
    } bpu_pred_t;

    // 主 BTB 两拍查询结果（第 4.2 节）。
    typedef struct packed {
        logic        hit;
        slot_mask_t  br_mask;
        slot_mask_t  jal_mask;
        fetch_slot_t cfi_slot;        // 唯一目标归属的槽位
        cfi_type_e   cfi_type;
        ras_action_e ras_action;
        vaddr_t      target;
    } btb_resp_t;

    // TAGE 三拍查询结果：8 槽位方向（D04）。
    typedef struct packed {
        slot_mask_t  taken_mask;
        slot_mask_t  provider_hit_mask;
        tage_meta_t  meta;
    } tage_resp_t;

    // 慢预测结果写回 FTQ：确认或覆盖；override=1 时同时发出 D24 慢覆盖请求。
    typedef struct packed {
        logic       valid;
        ftq_id_t    ftq_id;
        bpu_pred_t  pred;
        tage_meta_t tage_meta;
        logic       override;
    } bpu_slow_t;

    // 提交训练请求（D08，第 6.1 节）。使用原预测上下文，不在提交时重新查询。
    // 块内多条分支的排程、提交带宽和字段压缩待定。
    typedef struct packed {
        vaddr_t      region_base;
        hist_snapshot_t ctx;          // 原查询上下文（只需 C；是否传 E 待定）
        tage_meta_t  tage_meta;
        slot_mask_t  br_commit_mask;  // 已提交的条件分支槽位
        slot_mask_t  br_taken_mask;   // 其中实际 taken 的槽位
        logic        cfi_valid;       // 本区域提交的 taken CFI（主 BTB 单目标更新，D07）
        fetch_slot_t cfi_slot;
        cfi_type_e   cfi_type;
        ras_action_e ras_action;
        vaddr_t      cfi_target;
        logic        mispredicted;
    } bpu_train_t;

    // ============================================================
    // FTQ → ICache / 返回队列 / IFU
    // ============================================================
    // demand 请求：取该 FTQ entry 对应的对齐 16B（第 7.3 节）。
    typedef struct packed {
        vaddr_t  region_base;
        ftq_id_t ftq_id;
        rq_idx_t rq_idx;              // 发射前已预留的返回队列槽
        xlate_epoch_t epoch;          // 翻译上下文，用于隔离 satp 切换后的迟到结果（D27）
    } icache_req_t;

    // ICache 返回：允许乱序，按 rq_idx 写回返回队列（D14）。
    typedef struct packed {
        logic             valid;
        rq_idx_t          rq_idx;
        ftq_id_t          ftq_id;
        logic [REGION_BYTES*8-1:0] data;
        logic             exc_valid;  // ITLB/页权限/PMP/PMA 异常也必须完成队列项（第 8 节）
        exception_cause_t exc_cause;
    } icache_resp_t;

    // F0/F1 需要的 FTQ 最终预测摘要（慢预测之后），按 ftq_id 从 FTQ 读出。
    typedef struct packed {
        ftq_id_t    ftq_id;
        logic       slow_done;
        bpu_pred_t  pred;
    } ftq_pred_brief_t;

    // 返回队列出队给 F0 的原始块。
    typedef struct packed {
        ftq_id_t          ftq_id;
        vaddr_t           region_base;
        logic [REGION_BYTES*8-1:0] data;
        logic             exc_valid;
        exception_cause_t exc_cause;
    } rq_out_t;

    // F0 输出：已识别长度、拼接、RVC 展开的指令（第 3.3、10 节）。
    typedef struct packed {
        vaddr_t           pc;
        logic [ILEN-1:0]  raw_instruction;
        logic [ILEN-1:0]  instruction;
        logic [2:0]       inst_len;
        logic             is_rvc;
        logic             crosses_region; // 后半字来自下一个顺序区域
        ftq_id_t          ftq_id;         // 归属：起始半字所在区域
        fetch_slot_t      slot;
        logic             exc_valid;
        exception_cause_t exc_cause;
        logic [XLEN-1:0]  exc_tval;
    } f0_inst_t;

    // ============================================================
    // Frontend → Backend 交付（第 16.2 节）
    // ============================================================
    // 从 o3_pkg 迁入并补动态 FTQ 身份与槽位。
    // - raw_instruction 保存原始编码；RVC 用低 16 位，高 16 位清零。
    // - instruction 为规范 32 位指令；RVC 由前端展开。
    // - inst_len=2/4；取得编码前失败可为 0。非异常项 is_rvc <=> inst_len==2。
    // - ftq_last：当前 ROB 用它产生 FTQ 回收；目标合同为“区域有效指令全部提交后
    //   交接训练并回收”，是否仍由 ftq_last 标识，待与 ROB 提交合同核对。
    typedef struct packed {
        logic             valid;
        vaddr_t           pc;
        logic [ILEN-1:0]  raw_instruction;
        logic [ILEN-1:0]  instruction;
        logic [2:0]       inst_len;
        logic             is_rvc;
        logic             exception_valid;
        exception_cause_t exception_cause;
        logic [XLEN-1:0]  exception_tval;
        ftq_id_t          ftq_id;
        fetch_slot_t      slot;
        logic             ftq_last;
        logic             pred_taken;
        vaddr_t           predicted_next_pc;
    } fetch_entry_t;

    // ============================================================
    // Backend → Frontend：执行解析、提交、系统重定向
    // ============================================================
    // 单 BRU 解析结果（B12）。正确解析也送达，用于 FTQ 记录实际结果。
    typedef struct packed {
        logic        valid;
        logic        mispredict;
        ftq_id_t     ftq_id;
        fetch_slot_t slot;
        vaddr_t      branch_pc;
        logic [2:0]  inst_len;
        cfi_type_e   cfi_type;
        ras_action_e ras_action;
        logic        actual_taken;
        vaddr_t      actual_target;
        vaddr_t      redirect_pc;     // 正确的下一 PC
    } bru_resolve_t;

    // 提交端已正式接受的系统重定向（D24 规则 2：最高优先级）。
    // 主流程已定（B26/B27）：异常/中断在无正常退休的 trap 拍接受；合法 xRET 由自身退休触发。
    // 系统入口首笔取指允许与历史/RAS 恢复解耦（16.4/B30）；committed 预测上下文来源、
    // 入口取指的返回槽与元数据绑定仍待闭合。枚举只列来源，RTL 未实现。
    typedef enum logic [2:0] {
        SYS_EXCEPTION = 3'd0,         // B26：同步异常，EPC=故障指令 PC
        SYS_XRET      = 3'd1,         // B27：MRET/SRET
        SYS_INTERRUPT = 3'd2,         // B26：中断，EPC=committed_next_pc（B37）
        SYS_FENCE_I   = 3'd3,         // D25
        SYS_SFENCE    = 3'd4,         // D26
        SYS_SATP      = 3'd5,         // D27
        SYS_PMP       = 3'd6,         // D28
        SYS_OTHER     = 3'd7          // 其他需重新取指的串行化 CSR 写，范围未设计
    } sys_redirect_kind_e;

    typedef struct packed {
        logic               valid;
        sys_redirect_kind_e kind;
        ftq_id_t            ftq_id;
        fetch_slot_t        slot;
        vaddr_t             target_pc;
    } sys_redirect_t;

    // 提交通知：每条提交指令一项。region_last=1 表示该区域有效指令已全部提交。
    typedef struct packed {
        logic        valid;
        ftq_id_t     ftq_id;
        fetch_slot_t slot;
        logic        region_last;
    } ftq_commit_t;

    // ============================================================
    // D24 统一重定向请求、取消边界与恢复
    // ============================================================
    // 来源编码同时是同位置优先级：执行 > 预解码 > 慢预测；提交端系统重定向最高。
    typedef enum logic [1:0] {
        REDIR_SLOW      = 2'd0,
        REDIR_PREDECODE = 2'd1,
        REDIR_EXEC      = 2'd2,
        REDIR_SYS       = 2'd3
    } redirect_src_e;

    // 完整请求：PC、清除范围、历史/RAS 修正必须来自同一赢家。字段编码待定。
    typedef struct packed {
        logic          valid;
        redirect_src_e src;
        sys_redirect_kind_e sys_kind; // 仅 src==REDIR_SYS 有意义
        ftq_id_t       ftq_id;        // 出错位置；恢复装载该区域入口快照
        fetch_slot_t   slot;
        logic          kill_self;     // 1：清除包含本指令；0：只清除其后
        vaddr_t        target_pc;
        // 修正后的历史动作：正确结果为 taken 条件分支时注入一次事件（D23）。
        logic          hist_inject;
        vaddr_t        hist_branch_pc;
        vaddr_t        hist_target_pc;
        // 修正后的 RAS 动作（D29）：恢复入口 top_idx/count/top_addr 之后，按核实后的类型与
        // 原始长度再执行一次；不能沿用错误的 BTB 预测类型。
        ras_action_e   ras_fix;
        vaddr_t        ras_push_addr; // PC + 2/4
    } redirect_req_t;

    // 广播给各级的取消边界：比边界年轻的项失效。all=1 清除全部推测路径。
    typedef struct packed {
        logic        valid;
        logic        all;
        ftq_id_t     ftq_id;
        fetch_slot_t slot;
        logic        kill_self;
    } fe_kill_t;

    // ============================================================
    // 翻译：ITLB ↔ 共享 PTW（B07：PTW 共享 DCache；D26/D27）
    // ============================================================
    typedef enum logic [1:0] {
        PTW_SRC_IFETCH   = 2'd0,
        PTW_SRC_PREFETCH = 2'd1,
        PTW_SRC_DTLB     = 2'd2       // 后端 DTLB，同一 PTW；后端接入时确认
    } ptw_src_e;

    typedef struct packed {
        logic [VPN_W-1:0] vpn;
        asid_t            asid;
        xlate_epoch_t     epoch;
        ptw_src_e         src;
    } ptw_req_t;

    // 页表权限位与页大小。global 为遍历路径上的有效 G（D26）。
    typedef struct packed {
        logic             valid;
        logic [VPN_W-1:0] vpn;
        xlate_epoch_t     epoch;      // 与当前 epoch 不符的迟到结果丢弃，不安装（D27）
        ptw_src_e         src;
        logic [PPN_W-1:0] ppn;
        logic [1:0]       level;      // Sv39：0=4KiB，1=2MiB，2=1GiB
        logic             perm_r, perm_w, perm_x, perm_u, perm_g, perm_a, perm_d;
        logic             page_fault;
        logic             access_fault; // PTW 读取页表的物理权限错误（B06）
    } ptw_resp_t;

    // SFENCE.VMA 范围描述：保留寄存器编号是否为 x0，不用值为零代替（D26）。
    typedef struct packed {
        logic   valid;
        logic   rs1_is_x0;
        logic   rs2_is_x0;
        vaddr_t vaddr;
        asid_t  asid;
    } sfence_req_t;

    // ============================================================
    // CSR 派生状态 → 前端
    // ============================================================
    typedef struct packed {
        logic [1:0]   priv;           // 当前取指特权级；切换流程未设计
        logic [3:0]   satp_mode;
        asid_t        satp_asid;
        logic [43:0]  satp_ppn;
        xlate_epoch_t epoch;          // satp 有效写入后推进（D27）
    } fe_csr_t;

    typedef struct packed {
        logic [7:0]  cfg;             // pmpcfg 对应字节
        logic [53:0] addr;            // pmpaddr（RV64）
    } pmp_entry_t;

    typedef struct packed {
        logic                    update; // 有效修改脉冲：更新范围预解码派生状态（D28）
        pmp_entry_t [PMP_N-1:0]  entries;
    } pmp_state_t;

    // 前端系统同步请求（D25～D28）。由 commit_ctrl 统一编排（2026-10-02 确认）：
    // 前端 frontend_sync_ctrl 只负责前端部分（停取指/预取、隔离旧请求、ICache/ITLB/PMP 派生
    // 状态同步），不再自行发起 DCache clean。FENCE.I 的 SQ drain 与 L1D 脏行扫描在发出本请求前
    // 已由 commit_ctrl 完成（B23/D25 顺序）。
    typedef struct packed {
        sys_redirect_kind_e kind;
        sfence_req_t        sfence;
    } fe_sync_req_t;

    // ============================================================
    // L1I ↔ L2（第 11.1 节：L1→L2→总线，单核）
    // ============================================================
    typedef enum logic {
        L2_DEMAND   = 1'b0,
        L2_PREFETCH = 1'b1
    } l2_req_kind_e;

    typedef struct packed {
        paddr_t                 line_paddr;
        l2_req_kind_e           kind;
        logic [L2_TXN_ID_W-1:0] txn_id;
    } l2_req_t;

    typedef struct packed {
        logic                       valid;
        logic [L2_TXN_ID_W-1:0]     txn_id;
        logic [L2_BEAT_BYTES*8-1:0] data;
        logic                       last;
        logic                       error;
    } l2_resp_t;

    // L2 inclusive 回收（B41，2026-10-02 确认）：L2 淘汰某行前定向失效 L1I 与 L1D。
    // 首版每次两个 L1 都探测，不建 L1 驻留目录；recall_id 区分在途回收事务，旧应答不得
    // 确认新事务。L1I 无脏数据，只需失效并协调同行在途回填；L1D 应答见 dc_probe_resp_t。
    // 编码与 recall_id 宽度待定（随 L2 回收槽数 CFG.be.l2.recall_slots 确定）。
    localparam int L2_RECALL_SLOTS = O3_CFG.be.l2.recall_slots;
    localparam int L2_RECALL_ID_W  = (L2_RECALL_SLOTS > 1) ? $clog2(L2_RECALL_SLOTS) : 1;
    typedef logic [L2_RECALL_ID_W-1:0] l2_recall_id_t;

    typedef struct packed {
        paddr_t        line_paddr;
        l2_recall_id_t recall_id;
    } l1_recall_req_t;

    typedef struct packed {
        logic          valid;
        l2_recall_id_t recall_id;
        // 1：本 L1 已不再持有该行，且同行在途回填已被标记为不可安装（不会迟到重新装回）。
        logic        quiesced;
    } l1i_recall_resp_t;

    // ============================================================
    // 预取（D18/D19）
    // ============================================================
    typedef struct packed {
        vaddr_t       line_vaddr;
        logic         paddr_valid;    // 复用近期页翻译得到的物理地址
        paddr_t       line_paddr;
        asid_t        asid;
        xlate_epoch_t epoch;
    } pf_req_t;

    typedef enum logic [2:0] {
        PF_ISSUED     = 3'd0,         // 已向 L2 发出
        PF_HIT        = 3'd1,         // 已在 L1
        PF_INFLIGHT   = 3'd2,         // 已在途，合并
        PF_XLATE_FAIL = 3'd3,         // 翻译失败：不产生架构异常（第 11.2 节）
        PF_THROTTLED  = 3'd4          // 资源不足被节流
    } pf_status_e;

    typedef struct packed {
        logic             valid;
        pf_status_e       status;
        logic             xlate_valid; // 返回新翻译，供复用记录安装
        logic [VPN_W-1:0] vpn;
        logic [PPN_W-1:0] ppn;
        logic [1:0]       level;
    } pf_resp_t;

    // ============================================================
    // 性能事件（D21，第 12 节）
    // ============================================================
    // 每个事件每拍给出增量（同拍多事件不能被一个 Boolean 丢掉）。
    // 事件名为逻辑口径，不是已冻结的 CSR 编码；完整清单按第 12.2 节逐步补齐。
    localparam int PERF_INC_W = $clog2(REGION_SLOTS + 1);

    typedef enum int unsigned {
        PE_UBTB_LOOKUP, PE_UBTB_HIT,
        PE_FAST_SLOW_DISAGREE, PE_SLOW_OVERRIDE,
        PE_TAGE_COND_PRED, PE_TARGET_MISSING,
        PE_RAS_PUSH, PE_RAS_POP, PE_RAS_UNDERFLOW, PE_RAS_OVERFLOW, PE_RAS_LOG_FULL,
        PE_FTQ_FULL_CYCLE, PE_FTQ_EMPTY_CYCLE,
        PE_ICACHE_DEMAND_HIT, PE_ICACHE_DEMAND_MISS, PE_ICACHE_MSHR_MERGE,
        PE_ICACHE_REFILL_WAIT_CYCLE, PE_ICACHE_BANK_CONFLICT,
        PE_ITLB_HIT, PE_ITLB_MISS, PE_XLATE_REUSE,
        PE_PF_CANDIDATE, PE_PF_ISSUED, PE_PF_FILTERED, PE_PF_THROTTLED,
        PE_RQ_FULL_CYCLE, PE_RQ_HEAD_WAIT_SLOW_CYCLE, PE_RQ_HEAD_WAIT_DATA_CYCLE,
        PE_IFU_CROSS_REGION, PE_PREDECODE_REDIRECT,
        PE_DELIVER_LT4_BACKEND_READY_CYCLE, PE_BACKEND_BACKPRESSURE_CYCLE,
        PE_REDIRECT_EXEC, PE_REDIRECT_SYS, PE_RECOVER_CYCLE,
        PE_NUM
    } fe_perf_evt_e;

    typedef logic [PE_NUM-1:0][PERF_INC_W-1:0] fe_perf_t;

    // ============================================================
    // 后端：推导常量
    // ============================================================
    localparam int DECODE_W      = O3_CFG.be.decode.width;
    localparam int RENAME_W      = O3_CFG.be.rename.width;
    localparam int INT_PREGS     = O3_CFG.be.rename.int_phys_regs;
    localparam int FP_PREGS      = O3_CFG.be.rename.fp_phys_regs;
    localparam int INT_PREG_W    = $clog2(INT_PREGS);
    localparam int FP_PREG_W     = $clog2(FP_PREGS);
    localparam int PREG_W        = (INT_PREG_W > FP_PREG_W) ? INT_PREG_W : FP_PREG_W; // 两域共用字段宽度
    localparam int ROB_ENTRIES   = O3_CFG.be.rob.entries;
    localparam int ROB_IDX_W     = $clog2(ROB_ENTRIES);
    localparam int CKPT_N        = O3_CFG.be.rename.checkpoints;
    localparam int BR_TAG_W      = $clog2(CKPT_N);
    localparam int LQ_IDX_W      = $clog2(O3_CFG.be.lsu.lq_depth);
    localparam int SQ_IDX_W      = $clog2(O3_CFG.be.lsu.sq_depth);
    localparam int LQ_GEN_W      = O3_CFG.be.lsu.lq_gen_bits;
    localparam int DC_LINE_BYTES = O3_CFG.be.dcache.line_bytes;
    localparam int L2_LINE_BYTES = O3_CFG.be.l2.line_bytes;

    typedef logic [PREG_W-1:0]    preg_t;
    typedef logic [ROB_IDX_W-1:0] rob_idx_t;
    typedef logic [CKPT_N-1:0]    br_mask_t;
    typedef logic [BR_TAG_W-1:0]  br_tag_t;
    typedef logic [LQ_IDX_W-1:0]  lq_idx_t;
    typedef logic [SQ_IDX_W-1:0]  sq_idx_t;

    // ============================================================
    // 后端：寄存器域、FU 类别与操作编码（编码待定，只列逻辑内容）
    // ============================================================
    // 每个源/目的独立带域（B15）：FMV/FCVT/比较/分类跨域，不能按 FU 推断目的域。
    typedef enum logic [1:0] {
        RD_NONE = 2'd0,
        RD_INT  = 2'd1,
        RD_FP   = 2'd2
    } reg_domain_e;

    typedef enum logic [3:0] {
        FU_NONE      = 4'd0,
        FU_ALU       = 4'd1,
        FU_BRU       = 4'd2,
        FU_MUL       = 4'd3,
        FU_DIV       = 4'd4,
        FU_LDST      = 4'd5,   // 普通 load/store，含 FLW/FLD/FSW/FSD
        FU_AMO       = 4'd6,   // AMO 与 LR/SC：DCache 内受控执行（B09）
        FU_FMA       = 4'd7,   // FADD/FSUB/FMUL/四种 fused（B14）
        FU_FDIVSQRT  = 4'd8,
        FU_FMISC     = 4'd9,   // FSGNJ/FMIN/FMAX/FEQ/FLT/FLE/FCLASS
        FU_FCONV     = 4'd10,  // FCVT 与 FMV
        FU_CSR       = 4'd11,  // Zicsr：串行化，CSR 机制未设计
        FU_SYS       = 4'd12   // ECALL/EBREAK/xRET/WFI/FENCE/FENCE.I/SFENCE.VMA
    } fu_class_e;

    typedef enum logic [3:0] {
        MDU_MUL, MDU_MULH, MDU_MULHSU, MDU_MULHU, MDU_MULW,
        MDU_DIV, MDU_DIVU, MDU_REM, MDU_REMU,
        MDU_DIVW, MDU_DIVUW, MDU_REMW, MDU_REMUW
    } mdu_op_e;

    typedef enum logic [3:0] {
        AMO_LR, AMO_SC, AMO_SWAP, AMO_ADD, AMO_XOR, AMO_AND, AMO_OR,
        AMO_MIN, AMO_MAX, AMO_MINU, AMO_MAXU
    } amo_op_e;

    typedef enum logic [4:0] {
        FOP_ADD, FOP_SUB, FOP_MUL, FOP_MADD, FOP_MSUB, FOP_NMSUB, FOP_NMADD,
        FOP_DIV, FOP_SQRT,
        FOP_SGNJ, FOP_SGNJN, FOP_SGNJX, FOP_MIN, FOP_MAX,
        FOP_EQ, FOP_LT, FOP_LE, FOP_CLASS,
        FOP_CVT_F2F,          // FCVT.S.D / FCVT.D.S
        FOP_CVT_F2I,          // FCVT.W/WU/L/LU.{S,D}
        FOP_CVT_I2F,          // FCVT.{S,D}.W/WU/L/LU
        FOP_MV_F2X,           // FMV.X.W/D：位搬运，不做 NaN 替换（B14）
        FOP_MV_X2F            // FMV.W/D.X：单精度需 NaN-boxing
    } fp_op_e;

    typedef enum logic {
        FFMT_S = 1'b0,
        FFMT_D = 1'b1
    } fp_fmt_e;

    typedef enum logic [3:0] {
        SYSOP_NONE, SYSOP_ECALL, SYSOP_EBREAK, SYSOP_MRET, SYSOP_SRET, SYSOP_WFI,
        SYSOP_FENCE, SYSOP_FENCE_I, SYSOP_SFENCE_VMA
    } sys_op_e;

    typedef enum logic [1:0] {
        CSROP_NONE, CSROP_RW, CSROP_RS, CSROP_RC
    } csr_op_e;

    // MULH/MULHU/MULHSU + MUL 执行融合角色（B34，本项目方案，不是 BOOM/香山已有机制）。
    // - FUSE_HEAD：程序顺序在前的 MULH 类，携带唯一一次乘法执行请求与两个结果归属。
    // - FUSE_MEMBER：随后的 MUL，“不独立执行的融合成员”：仍有自己的 rename 目的映射、ROB 项和
    //   架构退休，但不进 IQ、不读 PRF、不形成第二次乘法请求；不是普通 NOP。
    typedef enum logic [1:0] {
        FUSE_NONE   = 2'd0,
        FUSE_HEAD   = 2'd1,
        FUSE_MEMBER = 2'd2
    } fuse_role_e;

    // 多实例模块的实例选择参数（无默认值）：同一模块按 KIND/DOMAIN 从 CFG 取各自规模。
    typedef enum logic [1:0] {
        IQ_INT = 2'd0,
        IQ_MEM = 2'd1,
        IQ_BR  = 2'd2,
        IQ_FP  = 2'd3     // FP IQ 组织待定（B14/B15）
    } iq_kind_e;

    // decoded_uop_t / renamed_uop_t 的框架扩展字段（o3_pkg 中以 ext 字段承载）。
    // 字段为逻辑内容，decoder 尚未产生，下游尚未消费。
    typedef struct packed {
        logic [REG_ADDR_WIDTH-1:0] rs3;          // FMA 第三源（B15）
        logic                      rs3_read_en;
        reg_domain_e               rs1_dom;
        reg_domain_e               rs2_dom;
        reg_domain_e               rs3_dom;
        reg_domain_e               rd_dom;
        fu_class_e                 fu_class;
        fetch_slot_t               ftq_slot;     // 动态 FTQ 槽位（前端 16.2 节）
        mdu_op_e                   mdu_op;
        amo_op_e                   amo_op;
        logic                      aq;           // A 扩展排序位（B09 首版较强排序，仍保留字段）
        logic                      rl;
        fp_op_e                    fp_op;
        fp_fmt_e                   fp_fmt;
        logic [FRM_W-1:0]          rm;           // 静态 rm；dynamic 需取程序顺序正确的 frm（B15）
        csr_op_e                   csr_op;
        logic                      csr_use_imm;  // CSRRWI/CSRRSI/CSRRCI
        logic [CSR_ADDR_W-1:0]     csr_addr;
        sys_op_e                   sys_op;
        logic                      serialize;    // 需在 ROB 队头串行执行
        // B22/B23/B24/B38：Decode→Rename 串行阻塞。1 表示本条之后的年轻指令在其退休前不得进入
        // Rename（CSR、FENCE、FENCE.I、SFENCE.VMA、WFI 等）。与 serialize 分开：前者管年轻放行，
        // 后者管本条在 ROB 队头执行。
        logic                      block_younger;
        // FENCE 的 pred/succ 编码保留（B23：按 pred.W 选择是否等 SQ drain）。
        logic [3:0]                fence_pred;
        logic [3:0]                fence_succ;
        // MULH 类 + MUL 执行融合（B34）：由 mul_fusion_detect 在 Decode Queue 出口、R1 之前标记。
        fuse_role_e                fuse_role;
    } uop_ext_t;

    typedef struct packed {
        preg_t                     src3_preg;
        logic                      src3_ready;
    } rename_ext_t;

    // R1 依赖预处理结果（B02）：每个源的“本组最近更老写入者”及 rd 的最近更老同名写入者。
    localparam int RENAME_SLOT_W = (RENAME_W > 1) ? $clog2(RENAME_W) : 1;

    typedef struct packed {
        logic                     valid;   // 依赖本组更老 lane
        logic [RENAME_SLOT_W-1:0] slot;    // 生产者在本组中的固定槽位
    } r1_dep_t;

    typedef struct packed {
        r1_dep_t src1;
        r1_dep_t src2;
        r1_dep_t src3;
        r1_dep_t rd_prev;                  // WAW：用于生成正确的 old_dst_preg
    } r1_lane_dep_t;

    // ============================================================
    // 后端：FU 请求身份、M / F 请求与结果
    // ============================================================
    // 每笔已接受的 FU 请求随数值推进的身份（B13/B14/B21）：
    // ROB 身份、目的域/preg、分支依赖。取消按 br_mask 选择性进行，保留老操作。
    // ROB 槽复用代际是否需要另加位，待“流水乘法完成端背压”等机制闭合时确定。
    typedef struct packed {
        rob_idx_t    rob_idx;
        br_mask_t    br_mask;
        reg_domain_e dst_dom;
        preg_t       dst_preg;
        logic        dst_write_en;
    } fu_tag_t;

    // ------------------------------------------------------------
    // MULH 类 + MUL 融合的双结果归属（B34）
    // ------------------------------------------------------------
    // 一次乘法执行请求携带两个结果归属：hi 属于 FUSE_HEAD（MULH/MULHU/MULHSU，取 [127:64]），
    // lo 属于 FUSE_MEMBER（MUL，取 [63:0]）。两个归属各自的 rob_idx/dst_preg/br_mask 独立，
    // 取消与迟到结果按各自身份过滤；两个结果可经完成 FIFO 分拍交付（不要求同拍写两个口）。
    typedef struct packed {
        logic     valid;          // 0：普通单结果乘法
        fu_tag_t  lo_tag;         // MUL 成员的结果归属
    } mdu_fuse_t;

    typedef struct packed {
        fu_tag_t          tag;          // 普通乘除；融合时为 FUSE_HEAD 的高位结果归属
        mdu_op_e          op;
        logic [XLEN-1:0]  src1;
        logic [XLEN-1:0]  src2;
        mdu_fuse_t        fuse;         // B34：融合时第二个（低位）结果归属；除法恒为 0
    } mdu_req_t;

    typedef struct packed {
        logic             valid;
        fu_tag_t          tag;
        logic [XLEN-1:0]  result;
    } mdu_resp_t;

    typedef struct packed {
        fu_tag_t          tag;
        fp_op_e           op;
        fp_fmt_e          fmt;
        logic [FRM_W-1:0] rm;            // 已解析为实际舍入模式
        logic             op_mod;        // 有/无符号整数转换等修饰位（编码待定）
        logic [XLEN-1:0]  src1;
        logic [XLEN-1:0]  src2;
        logic [XLEN-1:0]  src3;
    } fpu_req_t;

    typedef struct packed {
        logic                valid;
        fu_tag_t             tag;
        logic [XLEN-1:0]     result;     // 已完成 NaN-boxing / 整数扩展
        logic [FFLAGS_W-1:0] fflags;     // 随 ROB 保存，退休时按序并入（B15）
    } fpu_resp_t;

    // 统一写回候选：各结果槽保持到获得目的域写口为止。
    typedef struct packed {
        logic                valid;
        fu_tag_t             tag;
        logic [XLEN-1:0]     data;
        logic [FFLAGS_W-1:0] fflags;
    } wb_req_t;

    // ------------------------------------------------------------
    // 提前唤醒与 FU 完成 FIFO（B33）
    // ------------------------------------------------------------
    // 唤醒承诺：对结果交付时间已确定的流水 FU，在结果可被 bypass 前一拍广播目的 preg，
    // 让依赖者被提前安排。承诺一经发出不得因写回仲裁推迟而失效：
    // - 不可停顿流水 FU 在接受请求时必须已为该结果在完成 FIFO 中预留一项；
    // - 结果若未赢得写口，留在 FIFO 头，作为 bypass 源继续对已安排的消费者可见；
    // - FIFO 中尚不可交付（非头部、或尚未到达）的条目不能发出唤醒。
    // memory 不强求提前唤醒；迭代除法只有在结束时间已确定时才可发出。
    typedef struct packed {
        logic        valid;
        reg_domain_e dom;
        preg_t       preg;
        br_mask_t    br_mask;      // 被取消的承诺由消费者按同一取消边界丢弃
    } wake_promise_t;

    // 完成 FIFO 头的 bypass 源：头部已选结果可直接交付消费者，不要求先写 PRF（B33）。
    // valid 期间数据稳定；赢得写口的同一拍完成 PRF 写入，下一拍消费者改由 PRF 读取——
    // 由 PRF 写入与 bypass 退出的交接保证没有可见性空洞（具体交接拍数待 PRF 读写时序确定）。
    typedef struct packed {
        logic             valid;
        reg_domain_e      dom;
        preg_t            preg;
        logic [XLEN-1:0]  data;
    } cpl_bypass_t;

    typedef struct packed {
        logic             valid;
        exception_cause_t cause;
        logic [XLEN-1:0]  tval;
    } exc_info_t;

    // ============================================================
    // 访存：DCache / PTW / DMA（B03～B11）
    // ============================================================
    typedef enum logic [2:0] {
        DC_SRC_LOAD, DC_SRC_STORE_DRAIN, DC_SRC_AMO, DC_SRC_PTW,
        DC_SRC_PREFETCH, DC_SRC_PROBE,
        DC_SRC_PTE_AD             // B36：PTE 比较 + 条件置 A/D 的内部入口（旁侧状态机）
    } dc_src_e;

    // 访存事务身份：LQ 槽 + 代际，用于丢弃取消或复用后的迟到响应（B04）。
    typedef struct packed {
        lq_idx_t               idx;
        logic [LQ_GEN_W-1:0]   gen;
    } lq_tag_t;

    // Load 等待原因（B04/B32 新共识 1）。保守依赖：更老 store 地址未知时等待该依赖条件解除
    // （地址写入 SQ 或该 store 被取消/提交排出），不能实现成固定拍数超时后无条件越过；
    // 首版不加入未知旧 store 地址下的推测越过与违例恢复。每种原因由对应事件唤醒，避免每拍盲目重试。
    typedef enum logic [2:0] {
        LDW_NONE,
        LDW_OLDER_STORE_ADDR,   // 更老 store 地址未知
        LDW_OLDER_STORE_DATA,   // 完整覆盖的更老 store 数据未就绪 / 部分覆盖（保守等待）
        LDW_TLB_MISS,           // 等 PTW
        LDW_DCACHE,             // MSHR 回填 / bank 冲突 / MSHR 满（细分见 dc_status_e）
        LDW_DMA_BLOCK,          // DMA 行保护
        LDW_AD_ORDER            // 更老 store 的 D=0 慢路径未完成，年轻访存不得越过（B36）
    } ld_wait_e;

    typedef struct packed {
        dc_src_e          src;
        paddr_t           paddr;
        logic [1:0]       size;          // 1/2/4/8B
        logic             write;
        logic [XLEN-1:0]  wdata;
        logic [7:0]       wmask;
        amo_op_e          amo_op;
        lq_tag_t          lq_tag;        // load / replay 身份
        sq_idx_t          sq_idx;        // store drain 身份
    } dcache_req_t;

    // 区分等待原因，避免盲目重试（B04 6.2 节）。
    typedef enum logic [2:0] {
        DC_OK, DC_MISS_WAIT, DC_BANK_CONFLICT, DC_MSHR_FULL, DC_DMA_BLOCK, DC_ERROR
    } dc_status_e;

    typedef struct packed {
        logic             valid;
        dc_src_e          src;
        dc_status_e       status;
        lq_tag_t          lq_tag;
        sq_idx_t          sq_idx;
        logic [XLEN-1:0]  rdata;
        logic             sc_fail;       // SC 失败返回非零，不是异常（B09）
    } dcache_resp_t;

    // MSHR 回填完成唤醒：等待该行的 load 重查 SQ/cache（B04）。
    typedef struct packed {
        logic   valid;
        paddr_t line_paddr;
    } dc_wake_t;

    // TLB 查询结果（DTLB；ITLB 用独立端口，语义相同）。
    typedef struct packed {
        logic             hit;
        logic             miss;
        logic [PPN_W-1:0] ppn;
        logic [1:0]       level;
        logic             perm_r, perm_w, perm_x, perm_u, perm_a, perm_d;
        logic             page_fault;
        logic             access_fault;
    } tlb_resp_t;

    // 数据侧翻译与权限上下文（CSR 派生）。MPRV/SUM/MXR 等的精确来源随 CSR 设计闭合（未设计）。
    typedef struct packed {
        logic [1:0]   priv_eff;      // 有效访存特权级（考虑 MPRV）
        logic         sum;
        logic         mxr;
        logic [3:0]   satp_mode;
        asid_t        satp_asid;
        logic [43:0]  satp_ppn;
        xlate_epoch_t epoch;         // D27
    } dmmu_csr_t;

    // DMA 行事务（B08）：每笔一行，首版读写都 clean+invalidate L1D。
    typedef struct packed {
        logic                          write;
        paddr_t                        line_paddr;
        logic [L2_LINE_BYTES*8-1:0]    wdata;
        logic [L2_LINE_BYTES-1:0]      wmask;   // 部分行写保留未覆盖字节（B08）
    } dma_req_t;

    typedef struct packed {
        logic         valid;
        logic [L2_LINE_BYTES*8-1:0] rdata;
        logic         error;
    } dma_resp_t;

    // L2 → L1D 的维护探测，共用一个维护入口（2026-10-02 确认：常规 load/store 流水不新增
    // 一致性查询口；探测走维护队列与 bank 仲裁）：
    // - PROBE_DMA（B08）：行保护 + clean+invalidate；保留读/写意图，DMA 写取得行保护权时才与
    //   reservation 冲突检查排序（B35）。
    // - PROBE_RECALL（B41）：L2 inclusive 淘汰前定向失效；脏副本先交回最新数据再确认。
    //   容量回收不清 LR/SC reservation。
    typedef enum logic {
        PROBE_DMA    = 1'b0,
        PROBE_RECALL = 1'b1
    } dc_probe_kind_e;

    typedef struct packed {
        dc_probe_kind_e kind;
        paddr_t         line_paddr;
        logic           dma_write;    // 仅 PROBE_DMA 有意义
        l2_recall_id_t  recall_id;    // 仅 PROBE_RECALL 有意义
    } dc_probe_req_t;

    // 探测应答不依赖普通 miss 的空闲 MSHR（B41）；dirty_data 只在 had_dirty 时有效。
    typedef struct packed {
        logic           valid;
        dc_probe_kind_e kind;
        l2_recall_id_t  recall_id;
        logic           had_dirty;
        logic [DC_LINE_BYTES*8-1:0] dirty_data;
    } dc_probe_resp_t;

    // ------------------------------------------------------------
    // LR/SC reservation（B35）
    // ------------------------------------------------------------
    // 一条独立 reservation：物理 cache line 粒度用于冲突检测，另保留 LR 的物理地址与大小用于配对；
    // 首版只允许同物理地址、同大小的 SC 成功。无固定超时，不从 LR 到 SC 锁住 cache line。
    // 清除原因（逐项来自 B35 清除表）；未列出的事件不得清除，尤其：普通分支恢复、cache 替换、
    // clean、writeback、DMA 读、L2 容量回收。
    typedef enum logic [3:0] {
        RSV_CLR_SC,              // SC 执行（成功或失败）
        RSV_CLR_STORE_HIT,       // 本核 store drain / AMO 写到保留行
        RSV_CLR_DMA_WRITE,       // DMA 写取得行保护权且与保留行冲突（不是看到排队 valid）
        RSV_CLR_PTE_AD,          // PTW A/D 实际更新写到保留行
        RSV_CLR_TRAP,            // trap 入口
        RSV_CLR_XRET,            // 合法 xRET
        RSV_CLR_DEBUG,           // 进入 debug（完整 Debug Mode 未在首版范围，保留事件位）
        RSV_CLR_SFENCE_SATP      // 首版：SFENCE.VMA / 地址空间切换
    } rsv_clear_e;

    typedef struct packed {
        logic   valid;
        paddr_t paddr;           // 写入的物理地址（line 粒度比较）
    } rsv_conflict_t;

    // ------------------------------------------------------------
    // 硬件 A/D 更新（B36）
    // ------------------------------------------------------------
    // DCache 内部“完整 64 位 PTE 比较 + 条件置 A/D”入口。只由旁侧 pte_ad_updater 使用，
    // 普通 load/store 不经过它。比较不匹配时返回 mismatch，由 updater 重新遍历检查；
    // 不能直接 OR 后覆盖，也不是立即报 page fault。
    typedef struct packed {
        paddr_t           pte_paddr;
        logic [XLEN-1:0]  expected_pte;   // 遍历时读到的完整 PTE
        logic             set_a;
        logic             set_d;
        xlate_epoch_t     epoch;          // 取消/SFENCE/satp 后的失效上下文不得写入
    } pte_ad_req_t;

    typedef struct packed {
        logic             valid;
        logic             updated;        // 比较匹配且已条件写入
        logic             mismatch;       // PTE 已被改变：重新遍历
        logic             access_fault;   // 物理访问错误，归属原指令（退休前处理）
    } pte_ad_resp_t;

    // ------------------------------------------------------------
    // 晚到不可恢复写回错误（B39）
    // ------------------------------------------------------------
    // 首版只做 sticky fatal + 执行隔离，保持到复位；详细错误记录与调试后续接 FASE，本轮不扩展成
    // BEU/RAS 子系统。普通精确异常不得升级成 fatal。不能用仿真 $fatal 代替。
    typedef enum logic [1:0] {
        FATAL_L1D_WB,            // L1D 脏行写回 L2 失败
        FATAL_L2_WB,             // L2 写回 DDR 失败（AXI BRESP 错误等）
        FATAL_MAINT              // 维护/回收/DMA 协调中的写回失败
    } fatal_src_e;

    typedef struct packed {
        logic       valid;
        fatal_src_e src;
        paddr_t     line_paddr;   // 仅供后续 FASE 记录；首版不做软件可见报告
    } fatal_evt_t;

    // ============================================================
    // 系统：CSR、trap、提交
    // 主流程已定：B22（CSR 串行）、B23/B24（屏障）、B26（异常/中断）、B27（xRET）、
    // B29（复用 Breeze 特权语义）、B32（load 依赖等待）、B37（committed_next_pc）、B38（WFI）、B39（fatal）、
    // B40（FP 状态退休）。RTL 未实现；信号编码待定。
    // ============================================================
    typedef struct packed {
        csr_op_e               op;
        logic [CSR_ADDR_W-1:0] addr;
        logic [XLEN-1:0]       wdata;
        logic                  write_en;   // rs1=x0 的 CSRRS/CSRRC 不写（规范）
        rob_idx_t              rob_idx;
    } csr_req_t;

    typedef struct packed {
        logic             valid;
        logic [XLEN-1:0]  rdata;
        logic             illegal;
        logic             needs_refetch; // satp/PMP/特权相关写入：经 sys_redirect 清除年轻路径
        sys_redirect_kind_e refetch_kind;
    } csr_resp_t;

    // 提交到 trap_ctrl 的精确异常/中断/返回请求（B26/B27）。
    // - 同步异常：epc = 故障指令 PC；故障指令本身不退休，trap 拍无正常退休。
    // - 中断：epc = committed_next_pc（B37），ROB 为空时同样成立；不得用推测取指 PC 代替。
    // - xRET：合法队首 MRET/SRET 由自身正常退休触发，可与退休同拍。
    // - crossline_misalign：B31 计数用，原因随异常身份由 LSU 带到提交端，只在 trap 接受握手计一次。
    typedef struct packed {
        logic             valid;
        logic             is_xret;
        logic             is_mret;     // 区分 MRET/SRET
        logic             is_interrupt;
        exception_cause_t cause;
        logic [XLEN-1:0]  tval;
        vaddr_t           epc;
        logic             crossline_misalign;
    } trap_req_t;

    // 中断 pending/enable 的单项视图（B38 WFI 唤醒，B26 正式中断）：由 csr_file 输出。
    // WFI 唤醒 = |(mip & mie)，不额外要求全局 MIE/SIE，也不按委托结果屏蔽；
    // 正式进入中断仍按 B26/B29 的全局使能、特权级与委托规则判断。两者分开，不能共用一个条件。
    typedef struct packed {
        logic [XLEN-1:0]  mip;
        logic [XLEN-1:0]  mie;
    } irq_view_t;

    // 浮点架构状态退休事件（B40）：commit_ctrl 每拍合并一次交给 csr_file。
    // - fflags：按实际退休项 OR 合并（错误路径与 trap 拍不更新）。
    // - fs_dirty：本拍有退休项写架构 FPR，或退休项带非零 fflags（即使结果写整数寄存器）；
    //   不比较新旧数据。软件写浮点 CSR 在 CSR 串行更新点由 csr_file 自身置 Dirty。
    typedef struct packed {
        logic                valid;
        logic [FFLAGS_W-1:0] fflags;
        logic                fs_dirty;
    } fp_retire_evt_t;

    // ROB 队头每条提交指令的信息，供 commit_ctrl、提交 RAT、SQ、FTQ 回收、fflags 使用。
    typedef struct packed {
        logic                valid;
        rob_idx_t            rob_idx;
        vaddr_t              pc;
        logic [2:0]          inst_len;
        ftq_id_t             ftq_id;
        fetch_slot_t         slot;
        logic                region_last;
        reg_domain_e         rd_dom;
        logic [REG_ADDR_WIDTH-1:0] rd;
        logic                rd_write_en;
        preg_t               new_preg;
        preg_t               old_preg;
        logic                is_load;
        logic                is_store;
        lq_idx_t             lq_idx;
        sq_idx_t             sq_idx;
        logic [FFLAGS_W-1:0] fflags;
        sys_op_e             sys_op;
        uop_ext_t            ext;
        logic [31:0]         instruction;
        preg_t               src1_preg;
        logic [4:0]          rs1;
        logic                complete;
        exc_info_t           exc;
        // B37：本条实际退休后的下一架构 PC。普通指令 = 原始 PC + 真实指令长度；控制流 = 真实后继
        // PC（由 BRU 解析写回 ROB）。同拍多条退休取最后一条实际退休指令的 succ_pc。
        vaddr_t              succ_pc;
        logic                crossline_misalign; // B31：异常原因为跨 line 非对齐
        fuse_role_e          fuse_role;          // B34：融合成员仍各自退休
    } rob_commit_t;

    // 后端性能事件（B10 + B12/B13 建议的观测）。逻辑口径，不是 CSR 编码。
    typedef enum int unsigned {
        BE_RENAME_STALL_PREG, BE_RENAME_STALL_ROB, BE_RENAME_STALL_LQ, BE_RENAME_STALL_SQ,
        BE_RENAME_STALL_CKPT, BE_RENAME_STALL_RDQ,
        BE_BRANCH_READY_WAIT_READPORT, BE_BRANCH_RESULT_BLOCKED, BE_RESOLUTION_STALL_CYCLE,
        BE_MISPREDICT, BE_MUL_RESULT_BLOCKED, BE_DIV_BUSY_CYCLE,
        BE_DC_BANK_CONFLICT, BE_DC_MSHR_FULL, BE_DC_HIT_UNDER_MISS, BE_SQ_FORWARD, BE_SQ_WAIT,
        BE_PTW_WALK, BE_WALK_CACHE_HIT, BE_DPF_ISSUED, BE_DPF_USEFUL,
        BE_DMA_LINE_TXN, BE_DMA_LINE_LOCK_CYCLE, BE_DMA_CONFLICT_LOAD, BE_DMA_CONFLICT_STORE,
        BE_DMA_CONFLICT_CYCLE, BE_DMA_WAIT_DCACHE_CYCLE, BE_ROB_HEAD_DMA_WAIT_CYCLE,
        BE_ROB_FULL_CYCLE, BE_SQ_FULL_CYCLE,
        // B22：CSR 串行化成本
        BE_CSR_RETIRED, BE_CSR_WAIT_EMPTY_CYCLE, BE_CSR_BLOCK_YOUNGER_CYCLE,
        // B23：FENCE.I 次数与 L1D 数据维护周期
        BE_FENCEI_RETIRED, BE_FENCEI_DCACHE_EVICT_CYCLE,
        // B31：跨 line 非对齐正式陷入次数（trap 接受握手计一次）
        BE_MISALIGNED_CROSSLINE_TRAP,
        // B34：MULH+MUL 融合对数（观测，口径待定）
        BE_MUL_FUSED_PAIR,
        BE_PERF_NUM
    } be_perf_evt_e;

    localparam int BE_PERF_INC_W = $clog2(RENAME_W + 1);
    typedef logic [BE_PERF_NUM-1:0][BE_PERF_INC_W-1:0] be_perf_t;

endpackage
