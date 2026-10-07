// Integer RV64C expansion, translated from Flow AirRvcDecompressor.scala
// at 02e3f6fd2219186c9ddbe7cc7dd3e486ae9709f6 (L7b spec 2.2).
// 当前实现状态：闭环简化（L9）；lint/测试未运行，纯组合译码。
// L9 also expands RV64 C.FLD/C.FSD/C.FLDSP/C.FSDSP; f0 is writable.
module rvc_expander (
    input logic [15:0] in_i,
    output logic [31:0] out_o,
    output logic legal_o
);
    function automatic logic [31:0] enc_i(input logic [6:0] op, input logic [4:0] rd,
        input logic [2:0] f3, input logic [4:0] rs1, input logic [11:0] imm);
        return {imm,rs1,f3,rd,op};
    endfunction
    function automatic logic [31:0] enc_r(input logic [6:0] op, input logic [4:0] rd,
        input logic [2:0] f3, input logic [4:0] rs1,rs2,input logic [6:0] f7);
        return {f7,rs2,rs1,f3,rd,op};
    endfunction
    function automatic logic [31:0] enc_s(input logic [2:0] f3,
        input logic [4:0] rs1,rs2,input logic [11:0] imm);
        return {imm[11:5],rs2,rs1,f3,imm[4:0],7'b0100011};
    endfunction
    function automatic logic [31:0] enc_b(input logic [2:0] f3,
        input logic [4:0] rs1,input logic [12:0] imm);
        return {imm[12],imm[10:5],5'd0,rs1,f3,imm[4:1],imm[11],7'b1100011};
    endfunction
    function automatic logic [31:0] enc_j(input logic [20:0] imm);
        return {imm[20],imm[10:1],imm[11],imm[19:12],5'd0,7'b1101111};
    endfunction
    logic [15:0] c;
    logic [4:0] rd,rs2,rdp,rs1p;
    logic [11:0] simm,imm;
    logic [2:0] f3;
    assign c=in_i;
    assign rd=c[11:7];
    assign rs2=c[6:2];
    assign rdp={2'b01,c[4:2]};
    assign rs1p={2'b01,c[9:7]};
    always_comb begin
        out_o='0;legal_o=0;
        simm={{6{c[12]}},c[12],c[6:2]};imm='0;f3='0;
        case(c[1:0])
        2'b00: case(c[15:13])
            0: begin // ADDI4SPN
                imm={2'b0,c[10:7],c[12:11],c[5],c[6],2'b0};
                if(imm!=0) begin out_o=enc_i(7'h13,rdp,0,2,imm);legal_o=1;end
            end
            2,6: begin // LW / SW
                imm={5'b0,c[5],c[12:10],c[6],2'b0};
                out_o=c[15] ? enc_s(2,rs1p,rdp,imm):enc_i(7'h03,rdp,2,rs1p,imm);legal_o=1;
            end
            1,5: begin // FLD / FSD
                imm={4'b0,c[6:5],c[12:10],3'b0};
                out_o=c[15] ? {imm[11:5],rdp,rs1p,3'd3,imm[4:0],7'h27} : enc_i(7'h07,rdp,3,rs1p,imm);
                legal_o=1;
            end
            3,7: begin // LD / SD
                imm={4'b0,c[6:5],c[12:10],3'b0};
                out_o=c[15] ? enc_s(3,rs1p,rdp,imm):enc_i(7'h03,rdp,3,rs1p,imm);legal_o=1;
            end
            default:;
        endcase
        2'b01: case(c[15:13])
            0: begin out_o=enc_i(7'h13,rd,0,rd,simm);legal_o=1;end
            1: if(rd!=0) begin out_o=enc_i(7'h1b,rd,0,rd,simm);legal_o=1;end
            2: begin out_o=enc_i(7'h13,rd,0,0,simm);legal_o=1;end
            3: begin
                if(rd==2) begin
                    imm={{2{c[12]}},c[12],c[4:3],c[5],c[2],c[6],4'b0};
                    if(imm!=0) begin out_o=enc_i(7'h13,2,0,2,imm);legal_o=1;end
                end else if(rd!=0 && (|{c[12],c[6:2]})) begin
                    out_o={{14{c[12]}},c[12],c[6:2],rd,7'h37};legal_o=1;
                end
            end
            4: case(c[11:10])
                0: begin out_o=enc_i(7'h13,rs1p,5,rs1p,{6'b0,c[12],c[6:2]});legal_o=1;end
                1: begin out_o=enc_i(7'h13,rs1p,5,rs1p,{6'b010000,c[12],c[6:2]});legal_o=1;end
                2: begin out_o=enc_i(7'h13,rs1p,7,rs1p,simm);legal_o=1;end
                3: begin
                    if(!c[12]) begin
                        case(c[6:5])
                            0:f3=0;1:f3=4;2:f3=6;3:f3=7;
                        endcase
                        out_o=enc_r(7'h33,rs1p,f3,rs1p,rdp,c[6:5]==0 ? 7'h20:7'h00);legal_o=1;
                    end else if(c[6:5] inside {2'b00,2'b01}) begin
                        out_o=enc_r(7'h3b,rs1p,0,rs1p,rdp,c[6:5]==0 ? 7'h20:7'h00);legal_o=1;
                    end
                end
            endcase
            5: begin
                out_o=enc_j({{9{c[12]}},c[12],c[8],c[10:9],c[6],c[7],c[2],c[11],c[5:3],1'b0});legal_o=1;
            end
            6,7: begin
                out_o=enc_b(c[13] ? 3'd1:3'd0,rs1p,{{4{c[12]}},c[12],c[6:5],c[2],c[11:10],c[4:3],1'b0});legal_o=1;
            end
        endcase
        2'b10: case(c[15:13])
            0: if(rd!=0) begin out_o=enc_i(7'h13,rd,1,rd,{6'b0,c[12],c[6:2]});legal_o=1;end
            2: if(rd!=0) begin
                imm={4'b0,c[3:2],c[12],c[6:4],2'b0};out_o=enc_i(7'h03,rd,2,2,imm);legal_o=1;
            end
            1: begin // FLDSP, including f0
                imm={3'b0,c[4:2],c[12],c[6:5],3'b0};out_o=enc_i(7'h07,rd,3,2,imm);legal_o=1;
            end
            5: begin // FSDSP
                imm={3'b0,c[9:7],c[12:10],3'b0};out_o={imm[11:5],rs2,5'd2,3'd3,imm[4:0],7'h27};legal_o=1;
            end
            3: if(rd!=0) begin
                imm={3'b0,c[4:2],c[12],c[6:5],3'b0};out_o=enc_i(7'h03,rd,3,2,imm);legal_o=1;
            end
            4: begin
                if(rs2==0) begin
                    if(c[12] && rd==0) begin out_o=32'h00100073;legal_o=1;end
                    else if(rd!=0) begin out_o=enc_i(7'h67,c[12] ? 5'd1:5'd0,0,rd,0);legal_o=1;end
                end else if(rd!=0) begin
                    out_o=enc_r(7'h33,rd,0,c[12] ? rd:5'd0,rs2,0);legal_o=1;
                end
            end
            6: begin imm={4'b0,c[8:7],c[12:9],2'b0};out_o=enc_s(2,2,rs2,imm);legal_o=1;end
            7: begin imm={3'b0,c[9:7],c[12:10],3'b0};out_o=enc_s(3,2,rs2,imm);legal_o=1;end
            default:;
        endcase
        default:;
        endcase
    end
endmodule
