/**
 * O3 ISA 常量包 —— 由 RISC-V 规范固定、不属于可调参数的常量
 *
 * 只放 ISA 规定的宽度与编码：XLEN、ILEN、架构寄存器编号宽度、同步异常 cause。
 * 可调参数一律在 o3_cfg_pkg；推导类型在 o3_types_pkg；后端旧类型在 o3_pkg。
 * 依赖方向：o3_cfg_pkg、o3_isa_pkg ← o3_types_pkg ← o3_pkg（o3_pkg 重新导出本包）。
 *
 * cause 编码依据 RISC-V Privileged ISA（mcause 同步异常表）。中断 cause 未列入：
 * 异常/中断主流程已定（后端基线 B26/B27/B29，中断 EPC 来源 B37），RTL 未实现。
 *
 * 本阶段不写测试代码和仿真代码。
 */
package o3_isa_pkg;
    parameter int XLEN           = 64;   // RV64
    parameter int ILEN           = 32;   // 规范 32 位指令；RVC 由前端展开
    parameter int REG_ADDR_WIDTH = 5;    // x0..x31 / f0..f31
    parameter int NUM_ARCH_REGS  = 32;
    parameter int FFLAGS_W       = 5;    // NV/DZ/OF/UF/NX
    parameter int FRM_W          = 3;
    parameter int CSR_ADDR_W     = 12;

    typedef logic [5:0] exception_cause_t;
    localparam exception_cause_t EXCEPTION_CAUSE_INST_ADDR_MISALIGNED  = exception_cause_t'(0);
    localparam exception_cause_t EXCEPTION_CAUSE_INST_ACCESS_FAULT     = exception_cause_t'(1);
    localparam exception_cause_t EXCEPTION_CAUSE_ILLEGAL_INSTRUCTION   = exception_cause_t'(2);
    localparam exception_cause_t EXCEPTION_CAUSE_BREAKPOINT            = exception_cause_t'(3);
    localparam exception_cause_t EXCEPTION_CAUSE_LOAD_ADDR_MISALIGNED  = exception_cause_t'(4);
    localparam exception_cause_t EXCEPTION_CAUSE_LOAD_ACCESS_FAULT     = exception_cause_t'(5);
    localparam exception_cause_t EXCEPTION_CAUSE_STORE_ADDR_MISALIGNED = exception_cause_t'(6);  // 含 AMO
    localparam exception_cause_t EXCEPTION_CAUSE_STORE_ACCESS_FAULT    = exception_cause_t'(7);  // 含 AMO
    localparam exception_cause_t EXCEPTION_CAUSE_ECALL_U               = exception_cause_t'(8);
    localparam exception_cause_t EXCEPTION_CAUSE_ECALL_S               = exception_cause_t'(9);
    localparam exception_cause_t EXCEPTION_CAUSE_ECALL_M               = exception_cause_t'(11);
    localparam exception_cause_t EXCEPTION_CAUSE_INST_PAGE_FAULT       = exception_cause_t'(12);
    localparam exception_cause_t EXCEPTION_CAUSE_LOAD_PAGE_FAULT       = exception_cause_t'(13);
    localparam exception_cause_t EXCEPTION_CAUSE_STORE_PAGE_FAULT      = exception_cause_t'(15); // 含 AMO
endpackage
