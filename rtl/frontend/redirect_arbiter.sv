/**
 * 重定向仲裁器 —— D24 统一选择唯一赢家并控制恢复
 *
 * 作用：
 * - 收集四类重定向来源：提交端系统重定向、执行分支纠错、F1 预解码修正、慢预测覆盖。
 * - 选出唯一赢家，整份请求驱动 BPU 新 PC、取消边界广播、历史/RAS 恢复（RAS 按 D29 栈顶修复）。
 * - 锁存恢复过程直到历史与 RAS 恢复完成，期间停止新预测。
 *
 * 目标机制（D24，已定）：
 * 1) 先剔除已被取消或动态身份失效的请求。
 * 2) 提交端已正式接受的系统重定向优先；尚未到提交边界的年轻异常不能借用此优先级。
 * 3) 其余按程序顺序选最老：年龄由动态 FTQ 身份与块内槽位决定，相对 ftq_head_i
 *    处理环形回绕；不按 PC 数值比较。
 * 4) 同一位置：执行 > 预解码 > 慢预测（redirect_src_e 编码即此优先级）。
 * - 先产生独热赢家，再选整份请求；target、清除边界、快照引用、RAS 恢复信息不得
 *   各自用不一致的 mux 优先级。使用 Mux1H 时选择信号必须已是独热。
 * - 接受同拍：kill_o 广播，被清除的年轻路径不得继续分配、交付或修改推测状态。
 *   已被 ICache 接受的错误路径请求按 D17 完成并丢弃返回。
 * - 恢复期间收到仍有效且更老的请求：替换并重新恢复到更老检查点；同位置由更高
 *   优先级来源覆盖；被替换的旧恢复不得在随后完成时覆盖新状态。
 * - 执行纠错立即触发，不等待提交；预测表仍提交训练（D08）。
 * - Flow 参考教训（前端基线 6.5 节）：Breeze 提交 d951f6ae 的固定阶段优先级不能直接
 *   套用；这里按程序年龄仲裁。
 *
 * 普通分支恢复时序目标（D29，从前端接受重定向起算）：
 * - R0：接受唯一赢家，kill_o 广播，发起 E/C 快照与 ras_before 宽读取；
 * - R1：快照返回，恢复并修正 E/C 与 RAS（RAS 双写：栈顶修复 + 正确 call 压栈）；
 * - R2：BPU 从 target_pc 发起正常预测。
 * 恢复访问优先于竞争的提交训练。恢复工作量不随错误路径 push/pop 数增长。
 * 恢复身份：ras_recover_id_o / history 恢复均绑定赢家 ftq_id；被替换的旧恢复返回的 done
 * 不得错误解除阻塞（比对 ras_done_id_i）。
 *
 * 系统重定向（B26/B27/B30、前端 16.4）：
 * - 入口 PC 与新特权/翻译上下文可用后，允许在 N+1 发起入口首笔取指，与历史/RAS 恢复解耦，
 *   不要求先用 TAGE/RAS 预测这个已知地址；恢复中的旧历史/RAS 不得作为新上下文使用。
 * - 这条解耦只用于系统入口，不得成为普通分支恢复的降级路径。
 * - 仍待闭合（不在本框架冻结）：系统事件对应的 committed 预测上下文来源、FTQ 已释放或空 ROB
 *   时如何取得该边界、入口取指如何预留返回槽并在恢复后绑定预测元数据。未选择清空 RAS、
 *   独立 committed RAS 或复制 BOOM 系统 flush 清零历史。
 *
 * 细节待定：
 * - 字段编码；恢复控制握手的具体信号。
 * - 前后端各自的赢家归属：执行与提交两路都来自后端，后端自身的 checkpoint 恢复与
 *   这里的前端恢复如何保持同一取消边界，接口归属未设计（redirect_o 先作为后端观测口）。
 * - 系统重定向的入口 PC 由后端 trap_ctrl/csr_file 计算（B26/B27），这里只接收已形成的请求。
 *
 * 当前实现状态：闭环简化（L2 执行重定向）。
 * - 本级只接受 exec_i 的误预测；sys/predecode/slow 来源保持未实现。
 * - R0 同拍广播 kill、重定向 PC 并发起快照读取；锁存整份请求。
 * - R1 等待匹配身份的 history/RAS 完成；R2 解除 recover_busy，BPU 从目标继续分配。
 * - busy 期间仍有效且更老的执行纠错按 FTQ 环形年龄/块内槽位替换恢复（D24）；
 *   单 BRU 的解析顺序可能因操作数等待而乱序，不能据此丢弃更老解析。
 *
 * 目标周期行为：
 * - 周期 N 组合：比较所有有效请求，形成独热赢家；kill_o 与 bpu_redirect_* 有效。
 * - 周期 N 上升沿：锁存赢家，发起快照读与 ras_before 读；recover_busy_o 置 1。
 * - 周期 N+1（R1）：快照返回，branch_history 与 RAS 恢复修正；history_done_i && ras_done_i
 *   且 done 身份匹配当前赢家时，上升沿清除 busy。
 * - 周期 N+2（R2）：BPU 从 target_pc 恢复正常预测。
 *
 * 测试：sim/cocotb/branch_recovery/；多来源年龄仲裁不在本级测试范围。
 */
module redirect_arbiter
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic           clk_i,
    input  logic           rst_i,

    // 四类来源
    input  sys_redirect_t  sys_i,          // 提交端系统重定向
    input  bru_resolve_t   exec_i,         // 执行解析；mispredict=1 时形成请求
    input  redirect_req_t  predecode_i,    // F1 预解码修正
    input  redirect_req_t  slow_i,         // 慢预测覆盖

    // 年龄参照：FTQ 最老存活项身份
    input  ftq_id_t        ftq_head_i,

    // 赢家与取消边界
    output redirect_req_t  winner_o,
    output fe_kill_t       kill_o,
    output logic           bpu_redirect_valid_o,
    output vaddr_t         bpu_redirect_pc_o,

    // 恢复控制
    output logic           snap_rd_req_o,
    output ftq_id_t        snap_rd_ftq_id_o,
    input  logic           history_done_i,
    input  logic           ras_done_i,
    output logic           recover_busy_o, // 恢复期间停止新预测
    output ras_ckpt_t      ras_recover_ckpt_o, // 从 FTQ 读取的出错区域 ras_before（D29）
    input  ras_ckpt_t      ftq_ras_ckpt_i,
    output ftq_id_t        ras_recover_id_o,   // 当前恢复身份
    input  ftq_id_t        ras_done_id_i,      // RAS 完成通知所属身份

    // 后端观测口（归属待定，见文件头）
    output redirect_req_t  redirect_o,

    output fe_perf_t       perf_o
);
    redirect_req_t recover_q;
    logic          recover_busy_q;
    logic          accept_exec;
    logic          exec_older;
    int unsigned   exec_age, recover_age;
    redirect_req_t exec_req;

    // Live FTQ entries are ordered relative to the current head, including
    // wraparound. Generation is part of identity, never an age counter.
    // Within a region, use its slot; a repeated resolution cannot replace
    // itself. The backend filters resolutions killed by older branches.
    always_comb begin
        exec_age = int'(exec_i.ftq_id.idx) >= int'(ftq_head_i.idx)
                 ? int'(exec_i.ftq_id.idx) - int'(ftq_head_i.idx)
                 : int'(exec_i.ftq_id.idx) + CFG.ftq.depth - int'(ftq_head_i.idx);
        recover_age = int'(recover_q.ftq_id.idx) >= int'(ftq_head_i.idx)
                    ? int'(recover_q.ftq_id.idx) - int'(ftq_head_i.idx)
                    : int'(recover_q.ftq_id.idx) + CFG.ftq.depth - int'(ftq_head_i.idx);
        exec_older = (exec_age < recover_age)
                  || ((exec_i.ftq_id == recover_q.ftq_id)
                      && (exec_i.slot < recover_q.slot));
    end
    assign accept_exec = !rst_i && exec_i.valid && exec_i.mispredict
                       && (!recover_busy_q || exec_older);

    always_comb begin
        exec_req = '0;
        exec_req.valid = accept_exec;
        exec_req.src = REDIR_EXEC;
        exec_req.ftq_id = exec_i.ftq_id;
        exec_req.slot = exec_i.slot;
        exec_req.kill_self = 1'b0;
        exec_req.target_pc = exec_i.redirect_pc;
        exec_req.hist_inject = (exec_i.cfi_type == CFI_BR) && exec_i.actual_taken;
        exec_req.hist_branch_pc = exec_i.branch_pc;
        exec_req.hist_target_pc = exec_i.actual_target;
        exec_req.ras_fix = exec_i.ras_action;
        exec_req.ras_push_addr = exec_i.branch_pc + vaddr_t'(exec_i.inst_len);
    end

    // R0 uses the combinational request so cancellation and the new PC take
    // effect at the same edge that captures the recovery identity. During R1
    // winner_o remains the captured whole request for history/RAS correction.
    assign winner_o = accept_exec ? exec_req : recover_q;
    assign redirect_o = accept_exec ? exec_req : '0;
    assign kill_o = '{valid:accept_exec, all:1'b0,
                      ftq_id:exec_i.ftq_id, slot:exec_i.slot,
                      kill_self:1'b0};
    assign bpu_redirect_valid_o = accept_exec;
    assign bpu_redirect_pc_o = exec_i.redirect_pc;
    assign snap_rd_req_o = accept_exec;
    assign snap_rd_ftq_id_o = accept_exec ? exec_i.ftq_id : recover_q.ftq_id;
    assign recover_busy_o = recover_busy_q;
    assign ras_recover_ckpt_o = ftq_ras_ckpt_i;
    assign ras_recover_id_o = recover_q.ftq_id;
    assign perf_o = '0;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            recover_q <= '0;
            recover_busy_q <= 1'b0;
        end else begin
            if (accept_exec) begin
                recover_q <= exec_req;
                recover_busy_q <= 1'b1;
            end else if (recover_busy_q && history_done_i && ras_done_i
                      && ras_done_id_i == recover_q.ftq_id) begin
                recover_q <= '0;
                recover_busy_q <= 1'b0;
            end
        end
    end

endmodule
