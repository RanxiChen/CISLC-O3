/**
 * DCache 原子执行单元 —— AMO 与 LR/SC reservation（B09）
 *
 * AMO（已定基本路线）：
 * - 支持 RV64A .W/.D 的 swap/add/xor/and/or/min/max/minu/maxu；.W 旧值按规范符号扩展。
 * - 位于 ROB 队头，地址/权限/自然对齐/PMA 原子支持检查通过并满足先前访存排序后才执行；
 *   首版不支持非对齐原子；不支持原子的区域报适当异常，不模拟成普通读写。
 * - miss 通过 MSHR 等数据，不长时间占 bank；取得数据后短窗口保护目标行，完成读—运算—写，返回旧值。
 * - 与 DMA 对目标行互斥；CPU/PTW 同地址冲突访问也不能插入读改写窗口；其他行继续。
 * - 写入前确保结果有保存空间；修改后即使写回端口背压也只等待交付，绝不重执行。
 *   普通中断在不可撤销窗口内延后处理到安全边界（B26）。
 * - 异常按 store/AMO 类，不改报 load 异常。
 *
 * LR/SC（B35 已定，reservation 状态在独立 lrsc_reservation 中）：
 * - LR 在队首执行，读取数据与建立 reservation 处于一致的访问边界（rsv_set_o 与数据确认同拍）；
 *   LR 独立退休，不把 ROB 从 LR 锁到 SC；新 LR 替换旧记录。
 * - SC 先完成地址/权限/对齐/PMA 检查；miss 可以取行等待。取得数据与执行资源后，在短保护窗口内
 *   经 rsv_check 重新检查 reservation 并条件写入；不能提前锁定成功。首版只有同物理地址、同大小
 *   才成功。成功返回 0；失败不写、返回 1，不是异常；成功/失败都清除。
 * - 没抢到资源应等待，不能用 SC 失败替代公平仲裁；SC 回填及最终执行须有前进保障，不能被重复
 *   替换或 DMA 读无限抢占。
 * - 清除表见 lrsc_reservation；本模块不再有笼统的 reservation_clear_i。
 *
 * 排序：保留 aq/rl；首版较强排序：阻止年轻访存越过原子指令发射，在队头等待先前访存（含已提交
 * 未 drain 的 store）完成至所需顺序点。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module dcache_amo_unit
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG
) (
    input  logic            clk,
    input  logic            rst,

    input  logic            req_valid_i,
    output logic            req_ready_o,
    input  dcache_req_t     req_i,
    output dcache_resp_t    resp_o,

    // 与 DCache 主流水的行访问与锁
    output logic            line_lock_valid_o,
    output paddr_t          line_lock_paddr_o,
    output logic            array_req_valid_o,
    input  logic            array_req_ready_i,
    output dcache_req_t     array_req_o,
    input  dcache_resp_t    array_resp_i,

    // 与 lrsc_reservation 的接口
    output logic            rsv_set_o,
    output paddr_t          rsv_set_paddr_o,
    output logic [1:0]      rsv_set_size_o,
    output logic            rsv_check_o,
    output paddr_t          rsv_check_paddr_o,
    output logic [1:0]      rsv_check_size_o,
    input  logic            rsv_check_ok_i,
    output rsv_conflict_t   rsv_amo_conflict_o   // AMO 实际写（本核写保留行清除）
);
    // 未实现。
endmodule
