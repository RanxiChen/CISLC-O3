/** L8b pure RMW ALU. .W operations use 32-bit comparisons and wraparound. */
module dcache_amo_unit import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG
)(input amo_op_e op_i,input logic [1:0] size_i,input logic [63:0] old_i,data_i,
  output logic [63:0] new_o);
    logic [63:0] a,b,value;
    always_comb begin
        a=size_i==2 ? 64'(old_i[31:0]):old_i;
        b=size_i==2 ? 64'(data_i[31:0]):data_i;
        value=b;
        case(op_i)
            AMO_SWAP:value=b;
            AMO_ADD:value=a+b;
            AMO_XOR:value=a^b;
            AMO_AND:value=a&b;
            AMO_OR:value=a|b;
            AMO_MIN:value=(size_i==2 ? $signed(a[31:0])<$signed(b[31:0]):$signed(a)<$signed(b)) ? a:b;
            AMO_MAX:value=(size_i==2 ? $signed(a[31:0])>$signed(b[31:0]):$signed(a)>$signed(b)) ? a:b;
            AMO_MINU:value=a<b ? a:b;
            AMO_MAXU:value=a>b ? a:b;
            default:value=b;
        endcase
        new_o=size_i==2 ? 64'(value[31:0]):value;
    end
endmodule
