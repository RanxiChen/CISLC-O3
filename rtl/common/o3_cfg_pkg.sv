/**
 * O3 全局配置包 —— 全工程唯一写入参数数值的位置
 *
 * 组织规则（2026-10-02 用户确认）：
 * 1) 只有本包写数值。`o3_types_pkg` 只从 `O3_CFG` 推导位宽与跨模块 struct；
 *    各模块的 `parameter ... CFG` 不写默认值，由顶层逐级传入 `O3_CFG` 的子结构。
 * 2) 影响跨模块 struct 形状的参数（地址宽度、FTQ 身份、槽位、返回队列编号等）
 *    经 `o3_types_pkg` 变成全局类型；只影响模块内部规模的参数（way/set/MSHR/
 *    表项数）只经 CFG 进入模块。两者来自同一个 `O3_CFG`，不会出现两处数值。
 * 3) 每个字段注明状态与出处：
 *    - 已定：设计基线中已确认，改变需写明原因；
 *    - 暂定：基线接受的第一版数值，需保留测量后调整；
 *    - 待定：基线未冻结；当前数值只作首版实现估算；
 *    - 现状沿用：现有 RTL/仿真使用的值，基线没有对应决定。
 *    出处 Dxx 指前端设计基线，Bxx 指后端设计基线（均暂存于 Flow
 *    docs/cross-project/，目标工程为本仓库）。
 * 4) 2026-10-02 起，第一版容量值均为资源预算用的暂定值，不代表已通过
 *    综合、时序或板上验证；RTL 实测后仍可调整。O3_TBD 仅留给新增未估值字段。
 *
 * 当前范围：
 * - core 公共宽度、前端配置（2026-10-02 前端框架）、后端配置（2026-10-02 后端框架）。
 * - `o3_pkg` 中旧的 BACKEND_* 参数已改为从本包推导，不再自带数值。
 *
 * 工具支持：
 * - 2026-10-02 用 Verilator 5.050 lint 核实：unpacked struct 不能作为常量参数逐级传递
 *   （“Can't convert defparam value to constant”），因此配置结构一律使用 packed struct，
 *   数组字段用升序 packed 维 [0:N-1]，使 '{a,b,...} 中 a 对应下标 0。Vivado 尚未核实。
 * - 本包提供首版可编译的规模配置；功能正确性另由 RTL 测试验证。
 */
`ifndef O3_TBD
`define O3_TBD
`endif

package o3_cfg_pkg;

    // TAGE tagged 表数量决定配置数组形状，因此作为包级常量。
    // 暂定 6（D22），改动时同步 tage 字段的数组长度含义。
    localparam int TAGE_TABLES = 6;

    // ------------------------------------------------------------
    // core 公共宽度
    // ------------------------------------------------------------
    typedef struct packed {
        // 待定：RV64GC/Linux 下 Sv39 有效虚拟地址为 39 位符号扩展；PC/目标寄存
        // 保存 39、40 还是 64 位，以及非规范地址的异常检查方式未定（B12 第 4 条）。
        int unsigned vaddr_bits;
        // 待定：Sv39 物理地址最多 56 位；实现位宽依 KCU105 地址图确定。
        int unsigned paddr_bits;
        // 待定：实现支持的 ASID 位宽（D26 未定）。
        int unsigned asid_bits;
        // 待定：satp 切换与旧请求隔离使用的翻译上下文 epoch 位宽（D27 不固定）。
        int unsigned xlate_epoch_bits;
        // 已定 4：每拍 ROB 提交宽度，与 rename 一致（B42）。
        int unsigned commit_width;
        // 已定 8：M-mode mhpmcounter3～10；特权访问与 Sscofpmf 在 L10（B48）。
        int unsigned hpm_counters;
        // 待定：PMP 项数（D28 未定数量）。
        int unsigned pmp_entries;
    } core_cfg_t;

    // ------------------------------------------------------------
    // 前端：取指区域、交付与缓冲
    // ------------------------------------------------------------
    typedef struct packed {
        int unsigned region_bytes;        // 已定 16：16B 对齐预测/取指区域，8 个半字槽位（D03）
        int unsigned deliver_width;       // 已定 4：按序每拍最多交付 4 条（第 16.2 节）
        int unsigned return_queue_depth;  // 暂定 8：原始返回队列，参数化并测量占用（D15）
        int unsigned f0_slots;            // 待定：F0 每拍最多处理的槽位数（第 10 节）
        int unsigned f1_width;            // 待定：F1 每拍写入指令 buffer 的最大条数（第 10 节）
        int unsigned ibuf_depth;          // 待定：指令 buffer 深度（第 10 节、第 13 节第 6 条）
        // 现状沿用的旧串行 IFU 节流阈值；目标路径由返回队列预留控制取指，
        // 该字段可能随旧 icache_req_allowed 合同一起删除。
        int unsigned ibuf_req_free_threshold;
    } fetch_cfg_t;

    typedef struct packed {
        int unsigned depth;               // 待定：FTQ 深度（第 13 节第 3 条）
        int unsigned gen_bits;            // 待定：动态身份代际位宽，需定义回绕安全条件（第 7.1、10 节）
        int unsigned train_queue_depth;   // 待定：提交训练排队深度（第 6.1 节训练排程待定）
    } ftq_cfg_t;

    // ------------------------------------------------------------
    // 前端：预测器
    // ------------------------------------------------------------
    typedef struct packed {
        int unsigned entries;             // 待定：uBTB 容量；全相联/替换方式讨论过但未确认（第 4.1、16.3 节）
        int unsigned tag_bits;            // 待定
    } ubtb_cfg_t;

    typedef struct packed {
        int unsigned sets;                // 待定：主 BTB 容量（第 4.2 节）
        int unsigned ways;                // 待定：路数；“单目标”不等于直接映射（第 4.2 节）
        int unsigned tag_bits;            // 待定
    } btb_cfg_t;

    typedef struct packed {
        int unsigned event_bits;                      // 暂定 8：PC/target 事件编码宽度（D22）
        int unsigned event_window;                    // 暂定 128：事件序列 E 长度（D22）
        int unsigned fold_shift;                      // 暂定 2：折叠循环移位混合参数（D22）
        logic [0:TAGE_TABLES-1][31:0] hist_len;          // 暂定 4/8/16/32/64/128 次 taken 条件分支事件（D22）
        logic [0:TAGE_TABLES-1][31:0] index_bits;        // 待定：各表 2^n_i 行（D22 不冻结容量）
        logic [0:TAGE_TABLES-1][31:0] tag_bits;          // 待定：各表 tag 宽度 t_i >= 2（D22）
        int unsigned base_entries;                    // 待定：base 表容量（第 4.4 节）
        int unsigned ctr_bits;                        // 待定：方向计数器位宽
        int unsigned useful_bits;                     // 待定：useful 位宽
        int unsigned meta_bits;                       // 待定：随 FTQ 保存到提交训练的 provider 等元数据宽度
    } tage_cfg_t;

    typedef struct packed {
        int unsigned depth;               // 暂定 16：RAS 项数，循环覆盖最旧项（第 6.2 节）
        // 2026-10-02 D29：取消 undo log（原 undo_log_depth 字段删除），改为 FTQ 保存
        // {top_idx,count,top_addr} 的 BOOM 式栈顶快速修复，不再有 log 深度参数。
    } ras_cfg_t;

    // ------------------------------------------------------------
    // 前端：ICache、翻译与预取
    // ------------------------------------------------------------
    typedef struct packed {
        int unsigned line_bytes;          // 已定 64（D11）
        int unsigned banks;               // 已定 2：整条 line 交错，bank = addr[6]（D11/D12）
        int unsigned sets;                // 待定：容量未定；16KiB/4-way/64 sets 只是讨论例子（第 8 节）
        int unsigned ways;                // 待定（第 8 节）
        int unsigned mshrs;               // 待定：MSHR 数、合并 fanout、需求/预取份额（第 9.3 节）
        int unsigned refill_beat_bytes;   // 待定：回填 beat 宽度（第 9.1 节）
        int unsigned l2_txn_id_bits;      // 待定：L1I→L2 事务身份宽度（需覆盖 demand 与预取在途数）
    } icache_cfg_t;

    typedef struct packed {
        int unsigned entries;             // 待定：ITLB 容量；reg/SRAM 实现也未定（第 8 节）
        int unsigned ways;                // 待定：相联度
    } itlb_cfg_t;

    typedef struct packed {
        int unsigned xlate_reuse_entries; // 待定：预取近期页翻译复用记录项数（D19、第 11.2 节）
        int unsigned lead_distance;       // 待定：预取领先 demand 的距离（第 11.1 节）
        int unsigned req_queue_depth;     // 待定：去重后待发预取请求队列深度
    } prefetch_cfg_t;

    typedef struct packed {
        int unsigned counter_bits;        // 待定：硬件事件计数器位宽；读取 ABI、溢出与快照规则未设计（第 12.1 节）
    } perf_cfg_t;

    typedef struct packed {
        fetch_cfg_t    fetch;
        ftq_cfg_t      ftq;
        ubtb_cfg_t     ubtb;
        btb_cfg_t      btb;
        tage_cfg_t     tage;
        ras_cfg_t      ras;
        icache_cfg_t   icache;
        itlb_cfg_t     itlb;
        prefetch_cfg_t prefetch;
        perf_cfg_t     perf;
    } frontend_cfg_t;


    // ------------------------------------------------------------
    // 后端（出处 Bxx 指后端设计基线）
    // ------------------------------------------------------------
    typedef struct packed {
        int unsigned width;               // 已定 4：与前端每拍最多交付 4 条一致（前端 16.2 节）
        int unsigned queue_depth;         // L3 为 16：4 bank × 4 行，吸收后端回压（U1）
    } decode_cfg_t;

    typedef struct packed {
        int unsigned width;               // 已定 4：Decode/Rename/Dispatch/Commit 统一宽度（B42）
        int unsigned int_phys_regs;       // 待定：整数物理寄存器数（现状 96 不是基线决定）
        int unsigned fp_phys_regs;        // 已定 64：32 个架构 FPR 映射到 64 个 64 位物理 FPR（B15）
        int unsigned checkpoints;         // 待定：未决分支 checkpoint 数
        int unsigned rdq_depth;           // 待定：Rename/Dispatch Queue 深度
    } rename_cfg_t;

    typedef struct packed {
        int unsigned entries;             // 待定：ROB 项数
    } rob_cfg_t;

    typedef struct packed {
        int unsigned width;               // 已定 4：Dispatch 宽度（B42）
        int unsigned int_iq_depth;        // 待定
        int unsigned mem_iq_depth;        // 待定
        int unsigned br_iq_depth;         // 待定
        int unsigned fp_iq_depth;         // 待定：FP IQ 组织未定（B14/B15/B21），先给一个总深度
    } dispatch_cfg_t;

    typedef struct packed {
        int unsigned num_alu;             // 待定：整数 ALU 数（现状 4 不是基线决定）
        int unsigned int_prf_read_ports;  // 待定：整数 PRF 读口
        int unsigned int_prf_write_ports; // 待定：整数 PRF 写口
        int unsigned fp_prf_read_ports;   // 待定：两条三源 FMA 同拍最多 6 读，不等于已冻结 6 读（B14）
        int unsigned fp_prf_write_ports;  // 待定
        int unsigned mul_stages;          // B43：DSP 乘法四级实际流水，O3 包装额外延迟另计
        int unsigned mul_result_slots;    // 待定：乘法完成 FIFO 深度。机制已定（B33）：接受请求时预留完成空间，
                                          // 流水不停顿，唤醒承诺不因写回推迟而失效；深度未冻结
        int unsigned cpl_fifo_depth;      // 待定：其他流水 FU（ALU 结果槽外的 FP 等）完成 FIFO 深度（B33），
                                          // 首版可统一取值，测量后按 FU 拆分
        int unsigned div_max_iters;       // 已定方向 32：radix-4 最多 32 次迭代，不是 FU 固定延迟（B21）
        int unsigned num_fma;             // 已定 2：两个对称 FMA/ADDMUL FU（B14）
        int unsigned num_fdivsqrt;        // 已定 1（B14）
        int unsigned num_fmisc;           // 已定 1（B14）
        int unsigned num_fconv;           // 已定 1（B14）
        int unsigned fpu_inflight_slots;  // 待定：每个 FP FU 侧表的在途请求槽数（B14）
    } exec_cfg_t;

    typedef struct packed {
        int unsigned lq_depth;            // 待定
        int unsigned sq_depth;            // 待定
        int unsigned agu_pipes;           // 待定：“1 条 load + 1 条 load/store”只是建议（B03）
        int unsigned lq_gen_bits;         // 待定：LQ 事务身份代际宽度；现有 1 位不足（B04）
        logic [63:0] dtcm_base;           // 现状沿用 0x1100_0000：DTCM 不在基线中，去留未设计
        int unsigned dtcm_bytes;          // 现状沿用 256KiB：同上
    } lsu_cfg_t;

    typedef struct packed {
        int unsigned line_bytes;          // 待定：64B 为建议（B03）
        int unsigned sets;                // 待定：16KiB/4-way 为建议（B03）
        int unsigned ways;                // 待定
        int unsigned banks;               // 待定：4 bank、按整行或行内 word 映射均未冻结（B03）
        int unsigned mshrs;               // 待定：8 为建议（B03）
        int unsigned wb_buffers;          // 待定：脏行写回缓冲数
        int unsigned refill_beat_bytes;   // 待定
    } dcache_cfg_t;

    typedef struct packed {
        int unsigned dtlb_entries;        // 待定
        int unsigned dtlb_ways;           // 待定
        int unsigned walk_cache_entries;  // 待定：walk cache 层级与组织未定（B07）
        int unsigned ptw_slots;           // 待定：在途页表遍历数（D27 提到“唯一 PTW 槽”只是情形）
    } mmu_cfg_t;

    // L2 已定结构（B41，2026-10-02 用户确认）：首版纳入；inclusive（覆盖 L1I 与 L1D）；组相联；
    // tree-PLRU 替换（每 set ways-1 位，命中与安装时更新；选 victim 跳过正在回收/在途/受保护的 way）。
    // 以下规模参数均未冻结。
    typedef struct packed {
        int unsigned sets;                // 待定
        int unsigned ways;                // 待定：tree-PLRU 要求 2 的幂
        int unsigned line_bytes;          // 待定
        int unsigned mshrs;               // 待定：下级不能成为全局串行瓶颈（B03）
        int unsigned recall_slots;        // 待定：同时在途的 inclusive 回收事务数（B41）
        int unsigned wb_buffers;          // 待定：L2→DDR 写回可靠保存位置数；回收启动前预留（B41）
        int unsigned axi_id_bits;         // 待定
        int unsigned axi_data_bits;       // 待定
        int unsigned dma_inflight_lines;  // 已定 1：一笔 DMA 行协调事务在途（B08）
    } l2_cfg_t;

    typedef struct packed {
        int unsigned counter_bits;        // 待定：读取 ABI/位宽未定（B10）
    } be_perf_cfg_t;

    typedef struct packed {
        decode_cfg_t   decode;
        rename_cfg_t   rename;
        rob_cfg_t      rob;
        dispatch_cfg_t dispatch;
        exec_cfg_t     exec;
        lsu_cfg_t      lsu;
        dcache_cfg_t   dcache;
        mmu_cfg_t      mmu;
        l2_cfg_t       l2;
        be_perf_cfg_t  perf;
    } backend_cfg_t;

    typedef struct packed {
        core_cfg_t     core;
        frontend_cfg_t fe;
        backend_cfg_t  be;
    } o3_cfg_t;

    // ------------------------------------------------------------
    // 当前构建使用的唯一配置。以后可并列增加例如 O3_CFG_SIM_SMALL，
    // 用宏选择；任何模块都不得另写数值。
    // ------------------------------------------------------------
    // 首版资源预算：参考 BOOM Medium 的 32 项 FTQ/16 项 fetch buffer/64 项 ROB
    // 量级，但本核 16B 区域与 4 条交付更宽，预测表及队列需独立测量。
    // KCU105 XCKU040 片上 BRAM 为 21.1 Mb；本配置不是 FPGA fit 保证。
    localparam o3_cfg_t O3_CFG = '{
        core: '{
            vaddr_bits:        64,
            paddr_bits:        56,
            asid_bits:         16,
            xlate_epoch_bits:  8,
            commit_width:      4,
            hpm_counters:      8,
            pmp_entries:       16
        },
        fe: '{
            fetch: '{
                region_bytes:            16,
                deliver_width:           4,
                return_queue_depth:      8,
                f0_slots:                8,
                f1_width:                4,
                ibuf_depth:              16,
                ibuf_req_free_threshold: 8
            },
            ftq: '{
                depth:             32,
                gen_bits:          8,
                train_queue_depth: 4
            },
            ubtb: '{
                entries:  32,
                tag_bits: 12
            },
            btb: '{
                sets:     512,
                ways:     4,
                tag_bits: 16
            },
            tage: '{
                event_bits:   8,
                event_window: 128,
                fold_shift:   2,
                hist_len:     '{4, 8, 16, 32, 64, 128},
                index_bits:   '{10, 10, 10, 10, 10, 10},
                tag_bits:     '{8, 8, 8, 8, 8, 8},
                base_entries: 2048,
                ctr_bits:     3,
                useful_bits:  2,
                meta_bits:    128
            },
            ras: '{
                depth:          16
            },
            icache: '{
                line_bytes:        64,
                banks:             2,
                sets:              64,
                ways:              4,
                mshrs:             4,
                refill_beat_bytes: 16,
                l2_txn_id_bits:    4
            },
            itlb: '{
                entries: 32,
                ways:    4
            },
            prefetch: '{
                xlate_reuse_entries: 4,
                lead_distance:       2,
                req_queue_depth:     4
            },
            perf: '{
                counter_bits: 64
            }
        },
        be: '{
            decode: '{
                width:       4,
                queue_depth: 16
            },
            rename: '{
                width:         4,
                int_phys_regs: 96,
                fp_phys_regs:  64,
                checkpoints:   16,
                rdq_depth:     16
            },
            rob: '{
                entries: 64
            },
            dispatch: '{
                width:        4,
                int_iq_depth: 16,
                mem_iq_depth: 12,
                br_iq_depth:  8,
                fp_iq_depth:  12
            },
            exec: '{
                num_alu:             2,
                int_prf_read_ports:  4,
                int_prf_write_ports: 2,
                fp_prf_read_ports:   6,
                fp_prf_write_ports:  2,
                mul_stages:          4,
                mul_result_slots:    8,
                cpl_fifo_depth:      8,
                div_max_iters:       32,
                num_fma:             2,
                num_fdivsqrt:        1,
                num_fmisc:           1,
                num_fconv:           1,
                fpu_inflight_slots:  4
            },
            lsu: '{
                lq_depth:    16,
                sq_depth:    16,
                agu_pipes:   2,
                lq_gen_bits: 8,
                dtcm_base:   64'h0000_0000_1100_0000,
                dtcm_bytes:  256 * 1024
            },
            dcache: '{
                line_bytes:        64,
                sets:              64,
                ways:              4,
                banks:             4,
                mshrs:             4,
                wb_buffers:        2,
                refill_beat_bytes: 16
            },
            mmu: '{
                dtlb_entries:       32,
                dtlb_ways:          4,
                walk_cache_entries: 8,
                ptw_slots:          1
            },
            l2: '{
                sets:               256,
                ways:               4,
                line_bytes:         64,
                mshrs:              8,
                recall_slots:       2,
                wb_buffers:         4,
                axi_id_bits:        4,
                axi_data_bits:      128,
                dma_inflight_lines: 1
            },
            perf: '{
                counter_bits: 64
            }
        }
    };

endpackage
