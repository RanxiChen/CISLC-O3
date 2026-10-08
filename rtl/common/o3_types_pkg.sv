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
    import o3_isa_pkg::PRIV_U;
    import o3_isa_pkg::PRIV_S;
    import o3_isa_pkg::PRIV_M;
    import o3_isa_pkg::IRQ_SSI;
    import o3_isa_pkg::IRQ_MSI;
    import o3_isa_pkg::IRQ_STI;
    import o3_isa_pkg::IRQ_MTI;
    import o3_isa_pkg::IRQ_SEI;
    import o3_isa_pkg::IRQ_MEI;
    import o3_isa_pkg::IRQ_LCOFI;
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
    localparam int MEM_PADDR_W = O3_CFG.core.mem_paddr_bits;
    localparam int COH_ID_W = O3_CFG.fe.icache.l2_txn_id_bits;
    localparam int COH_ADDR_W = MEM_PADDR_W-$clog2(ICACHE_LINE_BYTES);
    localparam int COH_DATA_W = ICACHE_LINE_BYTES*8;
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
        logic        cfi_is_rvc;       // L7b: actual compressed length and edge ownership
        logic        is_edge;             // L7b: actual compressed length and edge ownership
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
        logic        cfi_is_rvc;       // L7b: actual compressed length and edge ownership
        logic        is_edge;             // L7b: actual compressed length and edge ownership
    } btb_resp_t;

    // TAGE 三拍查询结果：8 槽位方向（D04）。
    typedef struct packed {
        slot_mask_t  taken_mask;
        slot_mask_t  provider_hit_mask;
        tage_meta_t  meta;
    } tage_resp_t;

    localparam int LOOP_ENTRIES=o3_cfg_pkg::O3_CFG.fe.loop.entries,LOOP_ITER_BITS=o3_cfg_pkg::O3_CFG.fe.loop.iter_bits,LOOP_IDX_W=$clog2(LOOP_ENTRIES);
    localparam int TRAIN_CREDIT_W=$clog2(o3_cfg_pkg::O3_CFG.fe.ftq.train_queue_depth+1);
    typedef logic [LOOP_ENTRIES-1:0][LOOP_ITER_BITS-1:0] loop_ckpt_t;
    typedef struct packed {
        logic hit;
        logic [LOOP_IDX_W-1:0] idx;
        fetch_slot_t slot;
        logic used,pred;
    } loop_train_t;
    typedef struct packed {
        loop_train_t train;
        logic upd_valid,upd_taken;
        loop_ckpt_t ckpt;
    } loop_meta_t;
    localparam int META_PROVIDER_BITS=3;
    localparam int META_ALT_OFFSET=REGION_SLOTS*META_PROVIDER_BITS;
    localparam int META_PROVIDER_PRED_OFFSET=META_ALT_OFFSET+REGION_SLOTS;
    localparam int META_FINAL_OFFSET=META_PROVIDER_PRED_OFFSET+REGION_SLOTS;
    localparam int META_USED_BITS=META_FINAL_OFFSET+REGION_SLOTS;
    function automatic logic tage_final(input tage_meta_t meta,input int slot);
        return meta[META_FINAL_OFFSET+slot];
    endfunction
    // 慢预测结果写回 FTQ：确认或覆盖；override=1 时同时发出 D24 慢覆盖请求。
    typedef struct packed {
        logic       valid;
        ftq_id_t    ftq_id;
        bpu_pred_t  pred;
        tage_meta_t tage_meta;
        logic       override;
        loop_meta_t loop_meta;
    } bpu_slow_t;

    // 提交训练请求（D08，第 6.1 节）。使用原预测上下文，不在提交时重新查询。
    // 块内多条分支的排程、提交带宽和字段压缩待定。
    typedef struct packed {
        vaddr_t      region_base;
        logic [HIST_FOLD_W-1:0] folds;
        loop_train_t loop_train;
        tage_meta_t  tage_meta;
        slot_mask_t  br_commit_mask;  // 已提交的条件分支槽位
        slot_mask_t  br_taken_mask;   // 其中实际 taken 的槽位
        logic        cfi_valid;       // 本区域提交的 taken CFI（主 BTB 单目标更新，D07）
        fetch_slot_t cfi_slot;
        cfi_type_e   cfi_type;
        ras_action_e ras_action;
        vaddr_t      cfi_target;
        logic        mispredicted;
        logic        cfi_is_rvc;       // L7b: actual compressed length and edge ownership
        logic        is_edge;             // L7b: actual compressed length and edge ownership
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
        ras_ckpt_t  ras_ckpt;
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
        logic             is_edge;        // 起点在前一区域，归属后半字所在区域
        ftq_id_t          ftq_id;         // edge 归属后半字所在区域，其余归属起始半字所在区域
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
        logic             is_edge;
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
        logic exec_br_valid,exec_br_taken;
    } redirect_req_t;

    // 广播给各级的取消边界：比边界年轻的项失效。all=1 清除全部推测路径。
    typedef struct packed {
        logic        valid;
        logic        all;
        ftq_id_t     ftq_id;
        fetch_slot_t slot;
        logic        kill_self;
    } fe_kill_t;

    // Program age relative to the live FTQ head. Generation identifies a
    // dynamic entry; it is not an age counter. Slots order instructions within it.
    function automatic int unsigned fe_age(
        input ftq_id_t id, input fetch_slot_t slot, input ftq_id_t head
    );
        int unsigned region_age;
        region_age = (int'(id.idx) + FTQ_DEPTH - int'(head.idx)) % FTQ_DEPTH;
        return region_age * REGION_SLOTS + int'(slot);
    endfunction

    function automatic logic fe_killed_by(
        input fe_kill_t kill, input ftq_id_t id,
        input fetch_slot_t slot, input ftq_id_t head
    );
        return kill.valid && (kill.all
            || fe_age(id, slot, head) > fe_age(kill.ftq_id, kill.slot, head)
            || (kill.kill_self && id == kill.ftq_id && slot == kill.slot));
    endfunction

    // ============================================================
    // 翻译：ITLB ↔ 共享 PTW（B07：PTW 共享 DCache；D26/D27）
    // ============================================================
    localparam int SV39_VPN_W = 27;
    typedef logic [SV39_VPN_W-1:0] sv39_vpn_t;
    typedef logic [63:0] sv39_pte_t;
    typedef enum logic [1:0] {
        PTW_SRC_IFETCH   = 2'd0,
        PTW_SRC_PREFETCH = 2'd1,
        PTW_SRC_DCOMMIT  = 2'd3,
        PTW_SRC_DTLB     = 2'd2       // 后端 DTLB，同一 PTW；后端接入时确认
    } ptw_src_e;

    typedef struct packed {
        sv39_vpn_t vpn;
        asid_t asid;
        xlate_epoch_t epoch;
        ptw_src_e src;
        logic [43:0] root_ppn;
        logic [1:0] priv;
        logic is_store, sum, mxr, adue;
    } ptw_req_t;

    typedef struct packed {
        logic valid;
        sv39_vpn_t vpn;
        asid_t asid;
        xlate_epoch_t epoch;
        ptw_src_e src;
        logic [PPN_W-1:0] ppn;
        logic [1:0] level;
        logic perm_r, perm_w, perm_x, perm_u, perm_g, perm_a, perm_d;
        logic page_fault, access_fault;
        paddr_t pte_paddr;
        sv39_pte_t pte;
    } ptw_resp_t;

    function automatic logic sv39_canonical(input vaddr_t va);
        return va[63:39] == {25{va[38]}};
    endfunction
    function automatic logic sv39_covers(input sv39_vpn_t entry_vpn,
        input sv39_vpn_t vpn, input logic [1:0] level);
        case(level)
            2: return entry_vpn[26:18]==vpn[26:18];
            1: return entry_vpn[26:9]==vpn[26:9];
            default: return entry_vpn==vpn;
        endcase
    endfunction
    function automatic paddr_t sv39_pa(input logic [43:0] ppn,
        input vaddr_t va, input logic [1:0] level);
        case(level)
            2: return {ppn[43:18],va[29:0]};
            1: return {ppn[43:9],va[20:0]};
            default: return {ppn,va[11:0]};
        endcase
    endfunction
    function automatic logic sv39_perm(input logic [63:0] pte,
        input logic [1:0] priv, input logic fetch,store,sum,mxr);
        return (fetch ? pte[3] : store ? pte[2] : (pte[1] || (mxr && pte[3])))
            && (priv!=0 || pte[4]) && (priv!=1 || !pte[4] || (!fetch && sum));
    endfunction
    function automatic logic [2:0] mmu_plru_touch(input logic [2:0] old,
        input int way);
        logic [2:0] p;
        p=old; p[0]=(way<2); if(way<2) p[1]=(way==0); else p[2]=(way==2);
        return p;
    endfunction
    function automatic int mmu_plru_victim(input logic [2:0] p);
        return p[0] ? (p[2] ? 3 : 2) : (p[1] ? 1 : 0);
    endfunction

    // SFENCE.VMA 范围描述：保留寄存器编号是否为 x0，不用值为零代替（D26）。
    typedef struct packed {
        logic   valid;
        logic   rs1_is_x0;
        logic   rs2_is_x0;
        vaddr_t vaddr;
        asid_t  asid;
    } sfence_req_t;

    function automatic logic sfence_match(input sfence_req_t sf,
        input sv39_vpn_t vpn,input logic [1:0] level,input logic g,input asid_t asid);
        return (sf.rs1_is_x0 || sv39_covers(vpn,sf.vaddr[38:12],level)) &&
            (sf.rs2_is_x0 || (!g && asid==sf.asid));
    endfunction
    typedef struct packed {logic loop_dis,pf_dis;} fe_feat_t;
    // ============================================================
    // CSR 派生状态 → 前端
    // ============================================================
    typedef struct packed {
        fe_feat_t     fe_feat;
        logic [1:0]   priv;           // architectural privilege, L10
        logic         adue;
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
        logic en;
        logic [56:0] lo, hi;
        logic r, w, x, l;
    } pmp_dec_t;

    typedef struct packed {
        logic                    update; // 有效修改脉冲：更新范围预解码派生状态（D28）
        pmp_dec_t [PMP_N-1:0] dec;
        pmp_entry_t [PMP_N-1:0]  entries;
    } pmp_state_t;

    // L10 PMP range arithmetic is shared by the pipelined fetch checker and
    // the Bare LSU. Exclusive 57-bit bounds represent the entire PA space.
    // G=2: preserve raw storage, expose mode-dependent architectural bits.
    function automatic logic [53:0] pmp_addr_read(input pmp_entry_t entry);
        if (entry.cfg[4:3]==2'b11) return entry.addr | 54'd1;
        return entry.addr & ~54'd3;
    endfunction
    function automatic logic [56:0] pmp_lower(input pmp_state_t cfg, input int idx);
        logic [53:0] encoded;
        logic [56:0] addr, mask;
        int ones;
        encoded=pmp_addr_read(cfg.entries[idx]);
        addr={1'b0,encoded,2'b0}; ones=0; mask=0;
        case (cfg.entries[idx].cfg[4:3])
            2'b01: return idx==0 ? 57'd0 : {1'b0,(cfg.entries[idx-1].addr & ~54'd3),2'b0};
            2'b11: begin
                for (int n=0;n<54;n++) if (n==ones && encoded[n]) ones++;
                mask=(57'd1 << (ones+3))-1;
                return addr & ~mask;
            end
            default: return addr;
        endcase
    endfunction
    function automatic logic [56:0] pmp_upper(input pmp_state_t cfg, input int idx);
        logic [53:0] encoded;
        int ones;
        encoded=pmp_addr_read(cfg.entries[idx]); ones=0;
        case (cfg.entries[idx].cfg[4:3])
            2'b01: return {1'b0,(cfg.entries[idx].addr & ~54'd3),2'b0};
            2'b11: begin
                for (int n=0;n<54;n++) if (n==ones && encoded[n]) ones++;
                // NAPOT can encode ranges larger than the physical address space.
                if (ones>=53) return 57'd1 << 56;
                return pmp_lower(cfg,idx)+(57'd1 << (ones+3));
            end
            default: return pmp_lower(cfg,idx);
        endcase
    endfunction
    function automatic logic pmp_allow(input pmp_state_t cfg, input paddr_t addr,
        input int unsigned bytes, input logic [1:0] priv, input logic rd,wr,ex);
        logic [56:0] lo,hi,start_addr,end_addr;
        start_addr={1'b0,addr}; end_addr=start_addr+57'(bytes);
        for (int n=0;n<PMP_N;n++) begin
            lo=pmp_lower(cfg,n); hi=pmp_upper(cfg,n);
            if (cfg.entries[n].cfg[4:3]!=0 && start_addr<hi && end_addr>lo)
                return start_addr>=lo && end_addr<=hi &&
                    ((priv==PRIV_M && !cfg.entries[n].cfg[7]) ||
                     ((!rd || cfg.entries[n].cfg[0]) && (!wr || cfg.entries[n].cfg[1]) &&
                      (!ex || cfg.entries[n].cfg[2])));
        end
        return priv==PRIV_M;
    endfunction
    // CSR-side arithmetic only. XOR with the increment forms the trailing-one
    // mask, including 54-bit wraparound. The exclusive upper bound is 57 bits.
    function automatic logic [$bits(pmp_dec_t)*PMP_N-1:0] pmp_decode(
        input pmp_entry_t [PMP_N-1:0] entries);
        pmp_dec_t [PMP_N-1:0] d;
        logic [53:0] e, m;
        logic [56:0] mask, a;
        for (int n=0;n<PMP_N;n++) begin
            e=pmp_addr_read(entries[n]); m=e^(e+54'd1);
            a={1'b0,e,2'b0}; mask={1'b0,m,2'b11};
            d[n]='{en:entries[n].cfg[4:3]!=0,lo:a,hi:a,
                r:entries[n].cfg[0],w:entries[n].cfg[1],
                x:entries[n].cfg[2],l:entries[n].cfg[7]};
            case(entries[n].cfg[4:3])
                2'b01: begin
                    d[n].lo=n==0 ? 57'd0 : {1'b0,(entries[n-1].addr & ~54'd3),2'b0};
                    d[n].hi=a;
                end
                2'b11: begin
                    d[n].lo=a & ~mask;
                    d[n].hi=(a | mask)+57'd1;
                end
                default: ;
            endcase
        end
        return d;
    endfunction
    function automatic logic [$bits(pmp_dec_t)*PMP_N-1:0] pmp_decode_ref(
        input pmp_entry_t [PMP_N-1:0] entries);
        pmp_state_t c;
        pmp_dec_t [PMP_N-1:0] d;
        c='0;c.entries=entries;
        for(int n=0;n<PMP_N;n++)
            d[n]='{en:entries[n].cfg[4:3]!=0,lo:pmp_lower(c,n),hi:pmp_upper(c,n),
                r:entries[n].cfg[0],w:entries[n].cfg[1],x:entries[n].cfg[2],l:entries[n].cfg[7]};
        return d;
    endfunction
    function automatic logic pmp_allow_dec(input pmp_dec_t [PMP_N-1:0] dec,
        input paddr_t addr,input int unsigned bytes,input logic [1:0] priv,
        input logic rd,wr,ex);
        logic [PMP_N-1:0] match_bits, permissions;
        logic [56:0] a,b;
        logic result;
        a={1'b0,addr}; b=a+57'(bytes);
        for(int n=0;n<PMP_N;n++) begin
            match_bits[n]=dec[n].en && a<dec[n].hi && b>dec[n].lo;
            permissions[n]=a>=dec[n].lo && b<=dec[n].hi &&
                ((priv==PRIV_M && !dec[n].l) ||
                ((!rd || dec[n].r) && (!wr || dec[n].w) && (!ex || dec[n].x)));
        end
        result=priv==PRIV_M;
        for(int n=PMP_N-1;n>=0;n--) if(match_bits[n]) result=permissions[n];
        return result;
    endfunction
    function automatic logic pma_main(input logic [63:0] addr, input int unsigned bytes);
        logic [64:0] last_addr;
        last_addr={1'b0,addr}+65'(bytes);
        return bytes>0 && addr>=o3_cfg_pkg::PMA_MAIN_BASE && last_addr<=65'(o3_cfg_pkg::PMA_MAIN_END) && last_addr<=65'h100000000;
    endfunction
    function automatic logic pma_io(input logic [63:0] addr,input int unsigned bytes);
        return bytes>0 && addr>=o3_cfg_pkg::PMA_IO_BASE &&
            {1'b0,addr}+65'(bytes)<=65'(o3_cfg_pkg::PMA_MAIN_BASE);
    endfunction
    // 前端系统同步请求（D25～D28）。由 commit_ctrl 统一编排（2026-10-02 确认）：
    // 前端 frontend_sync_ctrl 只负责前端部分（停取指/预取、隔离旧请求、ICache/ITLB/PMP 派生
    // 状态同步）。FENCE.I 在 committed SQ 排空后发出本请求，不进行 L1D 全缓存维护。
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

    // L8a four independent coherence links. One beat carries one 64B line.
    typedef logic [COH_ADDR_W-1:0] coh_addr_t;
    typedef logic [COH_ID_W-1:0] coh_id_t;
    typedef logic [COH_DATA_W-1:0] coh_data_t;
    typedef enum logic [1:0] {COH_GETS,COH_GETM,COH_READ,COH_MASKWRITE} coh_req_op_e;
    typedef enum logic [1:0] {COH_PUT,COH_INVACK,COH_DOWNACK} coh_up_op_e;
    typedef enum logic {COH_INV,COH_DOWN} coh_snp_op_e;
    typedef enum logic [2:0] {COH_DATAS,COH_DATAE,COH_ACKE,COH_PUTACK,COH_READDATA,COH_WRITEACK} coh_down_op_e;
    typedef enum logic [1:0] {COH_I,COH_S,COH_E,COH_M} coh_state_e;
    typedef enum logic [1:0] {DIR_NONE,DIR_SHARED,DIR_UNIQUE} coh_dir_e;
    typedef struct packed {
        coh_req_op_e op; coh_addr_t addr; coh_id_t id;
        logic [ICACHE_LINE_BYTES-1:0] mask; coh_data_t data;
    } coh_req_t;
    typedef struct packed {
        coh_up_op_e op; logic has_data; coh_addr_t addr; coh_id_t id; coh_data_t data;
    } coh_rsp_up_t;
    typedef struct packed {coh_snp_op_e op; logic owner, dma_write; coh_addr_t addr;} coh_snp_t;
    typedef struct packed {coh_down_op_e op; coh_id_t id; logic error; coh_data_t data;} coh_rsp_down_t;
    // The task_kind payload is captured at S0, never reread from a mutable slot.
    localparam int L2_SLOT_W = $clog2(O3_CFG.be.l2.slots);
    localparam int L2_WAY_W = $clog2(O3_CFG.be.l2.ways);
    typedef enum logic [1:0] {L2_EVICT,L2_INSTALL,L2_REPLAY} l2_task_e;
    typedef enum logic [1:0] {L2_NEED_PROBE,L2_EVICT_DONE,L2_RETRY,L2_FINISHED} l2_done_e;
    typedef struct packed {
        logic [1:0] client; coh_req_t req; logic is_probe;
        logic [L2_WAY_W-1:0] way; logic victim_valid; coh_addr_t victim_addr;
        coh_snp_op_e probe_op; logic probe_owner;
        logic [L2_SLOT_W-1:0] slot; l2_task_e task_kind;
        coh_data_t refill; logic error, collected;
    } l2_work_t;

    // ============================================================
    // 预取（D18/D19）
    // ============================================================
    typedef struct packed {
        logic valid,hit;
        logic [PPN_W-1:0] ppn;
        logic [1:0] level;
        logic g;
    } xprobe_resp_t;
    typedef struct packed {
        logic valid;
        sv39_vpn_t vpn;
        logic [PPN_W-1:0] ppn;
        logic [1:0] level;
        logic g;
        asid_t asid;
        xlate_epoch_t epoch;
    } xlate_fill_t;
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
    // Frozen source-1 event numbers (mhpmevent[7:0]); zero means disabled.
    localparam int PERF_INC_W = $clog2(REGION_SLOTS + 1);

    typedef enum int unsigned {
        PE_UBTB_LOOKUP = 'h01,
        PE_UBTB_HIT = 'h02,
        PE_BTB_HIT = 'h03,
        PE_FAST_SLOW_DISAGREE = 'h04,
        PE_SLOW_OVERRIDE = 'h05,
        PE_TARGET_MISSING = 'h06,
        PE_PREDECODE_REDIRECT = 'h07,
        PE_REDIRECT_EXEC = 'h08,
        PE_REDIRECT_SYS = 'h09,
        PE_RECOVER_CYCLE = 'h0a,
        PE_RAS_PUSH = 'h0b,
        PE_RAS_POP = 'h0c,
        PE_RAS_UNDERFLOW = 'h0d,
        PE_RAS_OVERFLOW = 'h0e,
        PE_CMT_REGION = 'h0f,
        PE_CMT_FAST_OK_SLOW_OK = 'h10,
        PE_CMT_FAST_OK_SLOW_BAD = 'h11,
        PE_CMT_FAST_BAD_SLOW_OK = 'h12,
        PE_CMT_FAST_BAD_SLOW_BAD = 'h13,
        PE_CMT_MISPRED_REGION = 'h14,
        PE_FTQ_FULL_CYCLE = 'h15,
        PE_TAGE_COND_PRED = 'h20,
        PE_FTQ_EMPTY_CYCLE = 'h21,
        PE_ICACHE_DEMAND_HIT = 'h22,
        PE_ICACHE_DEMAND_MISS = 'h23,
        PE_ICACHE_MSHR_MERGE = 'h24,
        PE_ICACHE_REFILL_WAIT_CYCLE = 'h25,
        PE_ICACHE_BANK_CONFLICT = 'h26,
        PE_ITLB_HIT = 'h27,
        PE_ITLB_MISS = 'h28,
        PE_XLATE_REUSE = 'h29,
        PE_PF_CANDIDATE = 'h2a,
        PE_PF_ISSUED = 'h2b,
        PE_PF_FILTERED = 'h2c,
        PE_PF_THROTTLED = 'h2d,
        PE_RQ_FULL_CYCLE = 'h2e,
        PE_RQ_HEAD_WAIT_SLOW_CYCLE = 'h2f,
        PE_RQ_HEAD_WAIT_DATA_CYCLE = 'h30,
        PE_IFU_CROSS_REGION = 'h31,
        PE_DELIVER_LT4_BACKEND_READY_CYCLE = 'h32,
        PE_BACKEND_BACKPRESSURE_CYCLE = 'h33,
        PE_CMT_COND_BR = 'h34,
        PE_CMT_COND_MISPRED = 'h35,
        PE_CMT_COND_TAGE_WRONG = 'h36,
        PE_CMT_JALR = 'h37,
        PE_CMT_JALR_MISPRED = 'h38,
        PE_CMT_RET = 'h39,
        PE_CMT_RET_MISPRED = 'h3a,
        PE_CMT_LOOP_USED = 'h3b,
        PE_CMT_LOOP_WRONG = 'h3c,
        PE_TRAIN_STALL_CYCLE = 'h3d,
        PE_RQ_ZOMBIE = 'h3e,
        PE_PF_USEFUL='h3f, PE_PF_LATE='h40, PE_PF_UNUSED_EVICT='h41,
        PE_PF_XLATE_MISS='h42, PE_PF_XLATE_PROBE='h43,
        PE_NUM = 'h44
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

    // Project-owned integer conversion width; translated only inside FP wrappers.
    typedef enum logic { IFMT_W, IFMT_L } fp_int_fmt_e;

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
        IQ_FP  = 2'd3     // L9: unified three-source dual-issue FP IQ
    } iq_kind_e;

    // decoded_uop_t / renamed_uop_t 的框架扩展字段（o3_pkg 中以 ext 字段承载）。
    // L9 FP fields are produced by decoder and carried through rename/RDQ/IQ/RegRead.
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
        fp_fmt_e                   fp_fmt;      // destination floating format
        fp_fmt_e                   fp_src_fmt;
        fp_int_fmt_e               fp_int_fmt;
        logic                      fp_unsigned;
        logic                      uses_arch_rm;
        logic [FRM_W-1:0]          rm;           // 静态 rm；dynamic 需取程序顺序正确的 frm（B15）
        csr_op_e                   csr_op;
        logic                      csr_use_imm;  // CSRRWI/CSRRSI/CSRRCI
        logic [CSR_ADDR_W-1:0]     csr_addr;
        sys_op_e                   sys_op;
        logic                      sfence_rs1_x0;
        logic                      sfence_rs2_x0;
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
        fp_fmt_e          src_fmt;
        fp_fmt_e          dst_fmt;
        fp_int_fmt_e      int_fmt;
        logic [FRM_W-1:0] rm;            // 已解析为实际舍入模式
        logic             op_mod;        // unsigned integer conversion; wrapper maps fused op modifiers
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
    typedef enum logic [3:0] {
        LDW_NONE,LDW_OLDER_STORE_ADDR,LDW_OLDER_STORE_DATA,LDW_TLB_MISS,
        LDW_MSHR,LDW_MSHR_FULL,LDW_WB_LINE,LDW_CONFLICT,LDW_SNAP,LDW_BANK,LDW_AD_ORDER,LDW_HEAD
    } ld_wait_e;
    typedef enum logic [2:0] {DC_OK,DC_MISS_WAIT,DC_REPLAY,DC_ERROR} dc_status_e;
    typedef enum logic [1:0] {SQ_NORMAL,SQ_ATOMIC,SQ_MMIO,SQ_SPLIT} sq_kind_e;
    typedef struct packed {
        logic pmp_ok,exists,io,amo_ok,rsrv_ok,high_addr;
    } dc_permission_t;
    typedef struct packed {
        dc_src_e src; paddr_t paddr; vaddr_t vaddr; logic [1:0] size;
        logic write, is_sta, is_signed, is_flw, is_rob_head;
        logic head, check_only, split, raw, need_d; logic [3:0] bytes;
        logic [1:0] priv; dc_permission_t permission; logic access_valid,access_read,access_write;
        logic forward_valid, blocked, translation_miss;
        logic [XLEN-1:0] forward_data; exc_info_t exc;
        logic [XLEN-1:0] wdata; logic [7:0] wmask; amo_op_e amo_op;
        lq_tag_t lq_tag; sq_idx_t sq_idx; rob_idx_t rob_idx; br_mask_t br_mask;
    } dcache_req_t;
    typedef struct packed {
        logic valid; dc_src_e src; dc_status_e status; ld_wait_e reason;
        coh_id_t mshr_id; lq_tag_t lq_tag; sq_idx_t sq_idx;
        logic [XLEN-1:0] rdata; logic sc_fail,need_d,io,head; paddr_t paddr; exc_info_t exc;
    } dcache_resp_t;
    function automatic int dc_bytes(input dcache_req_t r);
        return r.bytes!=0 ? int'(r.bytes):(1<<int'(r.size));
    endfunction
    function automatic dc_permission_t dc_permissions(input dcache_req_t r,input pmp_state_t pmp,input logic [1:0] priv);
        dc_permission_t a; logic main,io,rd,wr;
        main=pma_main(64'(r.paddr),dc_bytes(r));io=pma_io(64'(r.paddr),dc_bytes(r));
        wr=r.write || r.is_sta;rd=!wr || (r.src==DC_SRC_AMO && !(r.amo_op inside {AMO_SC,AMO_LR}));
        if(r.access_valid) begin rd=r.access_read;wr=r.access_write;end
        a='{pmp_ok:pmp_allow_dec(pmp.dec,r.paddr,dc_bytes(r),priv,rd,wr,1'b0),exists:main || io,
            io:io,amo_ok:main,rsrv_ok:main,high_addr:((64'(r.paddr)>>MEM_PADDR_W)!=0)};
        return a;
    endfunction
    typedef struct packed {
        fu_tag_t tag; sq_kind_e kind; vaddr_t va; logic [63:0] data;
        logic [1:0] size; logic write,is_signed,is_flw; amo_op_e amo_op;
        sq_idx_t sq_idx; lq_tag_t lq_tag;
    } heu_req_t;
    function automatic logic [63:0] mem_format(input logic [63:0] raw,input logic [1:0] size,input logic sign_ext,input logic flw);
        case(size)
            0:return sign_ext ? 64'($signed(raw[7:0])):64'(raw[7:0]);
            1:return sign_ext ? 64'($signed(raw[15:0])):64'(raw[15:0]);
            2:return flw ? {32'hffffffff,raw[31:0]}:sign_ext ? 64'($signed(raw[31:0])):64'(raw[31:0]);
            default:return raw;
        endcase
    endfunction
    typedef struct packed {
        logic valid; coh_id_t mshr_id; logic err, mshr_free, wb_free;
    } dc_wake_t;
    localparam int DC_WAY_W=$clog2(O3_CFG.be.dcache.ways);
    typedef struct packed {
        coh_addr_t line_addr; logic is_getm, upgrade, atomic;
        logic [DC_WAY_W-1:0] way; logic wb_wait; coh_id_t wb_id;
        coh_data_t refill; logic err,grant_e,ack_e;
    } dc_line_txn_t;
    typedef enum logic [2:0] {DM_IDLE,DM_WB_READ,DM_SEND,DM_WAIT,DM_INSTALL} dc_mshr_state_e;
    typedef struct packed {
        coh_addr_t line_addr; logic has_data; logic [DC_WAY_W-1:0] way;
        coh_data_t data;
    } dc_wb_t;
    // TLB 查询结果（DTLB；ITLB 用独立端口，语义相同）。
    typedef struct packed {
        logic             hit;
        logic             miss;
        logic [PPN_W-1:0] ppn;
        logic [1:0]       level;
        logic             perm_r, perm_w, perm_x, perm_u, perm_g, perm_a, perm_d;
        logic             page_fault;
        logic             access_fault;
    } tlb_resp_t;

    // 数据侧翻译与权限上下文（CSR 派生）。MPRV/SUM/MXR 等的精确来源随 CSR 设计闭合（未设计）。
    typedef struct packed {
        logic [1:0]   priv_eff;      // 有效访存特权级（考虑 MPRV）
        logic [1:0]   priv;
        logic         mprv;
        logic [1:0]   mpp;
        logic         adue;
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

    // ------------------------------------------------------------
    // LR/SC reservation（B35）
    // ------------------------------------------------------------
    // 一条独立 reservation：物理 cache line 粒度用于冲突检测，另保留 LR 的物理地址与大小用于配对；
    // 只允许同物理地址、同大小的 SC 成功；timer 只限制 probe 延迟，不限制 reservation 寿命。
    // L8b Y3：同行 Inv 与逐出也清除；Down、普通 load、其他行写、timer 到期和分支恢复不清除。
    typedef enum logic [3:0] {
        RSV_CLR_INV, RSV_CLR_EVICT,
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
    // B40（FP 状态退休）在 L9 接通；后级中断/S/U/维护合同仍待各级实现。
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
    typedef struct packed {
        logic             valid;
        logic             is_xret;
        logic             is_mret;     // 区分 MRET/SRET
        logic             is_interrupt;
        exception_cause_t cause;
        logic [XLEN-1:0]  tval;
        vaddr_t           epc;
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
        preg_t               src2_preg;
        logic [4:0]          rs1;
        logic                complete;
        exc_info_t           exc;
        // B37：本条实际退休后的下一架构 PC。普通指令 = 原始 PC + 真实指令长度；控制流 = 真实后继
        // PC（由 BRU 解析写回 ROB）。同拍多条退休取最后一条实际退休指令的 succ_pc。
        vaddr_t              succ_pc;
        logic                needs_d; // L10: complete store waits for queue-head non-speculative D update
        fuse_role_e          fuse_role;          // B34：融合成员仍各自退休
    } rob_commit_t;

    // Frozen source-2 event numbers (mhpmevent[7:0]); append, never reorder.
    // Zero is disabled. Existing producers retain their current event semantics.
    typedef enum int unsigned {
        BE_RENAME_STALL_PREG = 'h01,
        BE_RENAME_STALL_ROB = 'h02,
        BE_RENAME_STALL_LQ = 'h03,
        BE_RENAME_STALL_SQ = 'h04,
        BE_RENAME_STALL_CKPT = 'h05,
        BE_RENAME_STALL_RDQ = 'h06,
        BE_BRANCH_READY_WAIT_READPORT = 'h07,
        BE_BRANCH_RESULT_BLOCKED = 'h08,
        BE_RESOLUTION_STALL_CYCLE = 'h09,
        BE_MISPREDICT = 'h0a,
        BE_MUL_RESULT_BLOCKED = 'h0b,
        BE_DIV_BUSY_CYCLE = 'h0c,
        BE_DC_BANK_CONFLICT = 'h0d,
        BE_DC_MSHR_FULL = 'h0e,
        BE_DC_HIT_UNDER_MISS = 'h0f,
        BE_SQ_FORWARD = 'h10,
        BE_SQ_WAIT = 'h11,
        BE_PTW_WALK = 'h12,
        BE_WALK_CACHE_HIT = 'h13,
        BE_DPF_ISSUED = 'h14,
        BE_DPF_USEFUL = 'h15,
        BE_DMA_LINE_TXN = 'h16,
        BE_DMA_LINE_LOCK_CYCLE = 'h17,
        BE_DMA_CONFLICT_LOAD = 'h18,
        BE_DMA_CONFLICT_STORE = 'h19,
        BE_DMA_CONFLICT_CYCLE = 'h1a,
        BE_DMA_WAIT_DCACHE_CYCLE = 'h1b,
        BE_ROB_HEAD_DMA_WAIT_CYCLE = 'h1c,
        BE_ROB_FULL_CYCLE = 'h1d,
        BE_SQ_FULL_CYCLE = 'h1e,
        // B22：CSR 串行化成本
        BE_CSR_RETIRED = 'h1f,
        BE_CSR_WAIT_EMPTY_CYCLE = 'h20,
        BE_CSR_BLOCK_YOUNGER_CYCLE = 'h21,
        // B23/B51：FENCE.I 退休次数；旧数据维护周期槽取消
        BE_FENCEI_RETIRED = 'h22,
        BE_FENCEI_DCACHE_EVICT_CYCLE = 'h23, // 已取消（B51 40.7），恒 0
        // 成功退休的跨行拆分（B49）
        BE_MISALIGNED_CROSSLINE_SPLIT = 'h24,
        // B34：MULH+MUL 融合对数（观测，口径待定）
        BE_MUL_FUSED_PAIR = 'h25,
        BE_DTLB_MISS = 'h26,
        BE_PTE_A_UPDATE = 'h27,
        BE_PTE_D_UPDATE = 'h28,
        BE_SFENCE = 'h29,
        BE_DC_MSHR_ALLOC = 'h2a, BE_DC_MSHR_MERGE = 'h2b,
        BE_DC_REPLAY_SNAP = 'h2c, BE_DC_WB_PUT = 'h2d, BE_DC_PROBE = 'h2e,
        BE_RFO_ISSUED = 'h2f, BE_RFO_DROPPED = 'h30, BE_DC_MSHR_OCCUPANCY = 'h31,
        BE_L2_HIT = 'h32, BE_L2_MISS = 'h33, BE_L2_SLOT_FULL = 'h34,
        BE_L2_PROBE = 'h35, BE_L2_WRITEBACK = 'h36, BE_RFO_USEFUL = 'h37,
        BE_AMO_EXEC='h39, BE_LR_EXEC='h3a, BE_SC_FAIL='h3b,
        BE_RSV_PROBE_HOLD_CYCLE='h3c, BE_MMIO_READ='h3d, BE_MMIO_WRITE='h3e,
        BE_LD_ORDER_FLUSH='h3f, BE_DMA_READ='h40, BE_DMA_WRITE='h41,
        BE_PERF_NUM = 'h42
    } be_perf_evt_e;

    localparam int BE_PERF_INC_W = $clog2(O3_CFG.be.l2.slots + 1);
    typedef logic [BE_PERF_NUM-1:0][BE_PERF_INC_W-1:0] be_perf_t;

endpackage
