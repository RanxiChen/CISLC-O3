/** AXI line engine. One read ID per slow slot, independent per-ID assembly.
 * Two writes retain data through B. Reads of buffered write lines wait for B.
 * AW and W use one ordered serializer; BID frees the named write buffer. */
module l2_mem_engine import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG,localparam int N=CFG.l2.slots,
    localparam int WN=CFG.l2.mem_write_buffers,localparam int ID_W=CFG.l2.axi_id_bits,
    localparam int DATA_W=CFG.l2.axi_data_bits,localparam int BEATS=COH_DATA_W/DATA_W
)(input logic clk,rst,input logic read_valid_i,output logic read_ready_o,
    input logic [L2_SLOT_W-1:0] read_slot_i,input coh_addr_t read_addr_i,
    output logic read_done_o,output logic [L2_SLOT_W-1:0] read_done_slot_o,
    output coh_data_t read_data_o,output logic read_error_o,
    input logic wb_push_i,input coh_addr_t wb_addr_i,input coh_data_t wb_data_i,output logic wb_free_o,
    output fatal_evt_t fatal_o,
    output logic m_axi_awvalid,input logic m_axi_awready,output logic [ID_W-1:0] m_axi_awid,
    output logic [PADDR_W-1:0] m_axi_awaddr,output logic [7:0] m_axi_awlen,
    output logic [2:0] m_axi_awsize,output logic [1:0] m_axi_awburst,
    output logic m_axi_wvalid,input logic m_axi_wready,output logic [DATA_W-1:0] m_axi_wdata,
    output logic [DATA_W/8-1:0] m_axi_wstrb,output logic m_axi_wlast,
    input logic m_axi_bvalid,output logic m_axi_bready,input logic [ID_W-1:0] m_axi_bid,input logic [1:0] m_axi_bresp,
    output logic m_axi_arvalid,input logic m_axi_arready,output logic [ID_W-1:0] m_axi_arid,
    output logic [PADDR_W-1:0] m_axi_araddr,output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,output logic [1:0] m_axi_arburst,
    input logic m_axi_rvalid,output logic m_axi_rready,input logic [ID_W-1:0] m_axi_rid,
    input logic [DATA_W-1:0] m_axi_rdata,input logic [1:0] m_axi_rresp,input logic m_axi_rlast);
    logic rd_busy_q[N],rd_err_q[N];coh_data_t rd_data_q[N];int rd_beat_q[N];
    logic wb_valid_q[WN],wb_sent_q[WN];coh_addr_t wb_addr_q[WN];coh_data_t wb_data_q[WN];
    int wb_free_idx,send_idx,send_q,wbeat_q;logic send_valid_q,aw_done_q;logic raw_block;
    always_comb begin
        wb_free_idx=-1;send_idx=-1;raw_block=0;
        for(int n=WN-1;n>=0;n--) begin
            if(!wb_valid_q[n]) wb_free_idx=n;
            if(wb_valid_q[n] && !wb_sent_q[n]) send_idx=n;
            if(wb_valid_q[n] && wb_addr_q[n]==read_addr_i) raw_block=1;
        end
        // RAW in the same cycle as an EVICT handoff is blocked as well.
        if(wb_push_i && wb_addr_i==read_addr_i) raw_block=1;
        wb_free_o=wb_free_idx>=0;
        m_axi_arvalid=read_valid_i && !raw_block && !rd_busy_q[read_slot_i];
        read_ready_o=m_axi_arready && !raw_block && !rd_busy_q[read_slot_i];
        m_axi_arid=ID_W'(read_slot_i);m_axi_araddr=PADDR_W'({read_addr_i,6'b0});
        m_axi_arlen=8'(BEATS-1);m_axi_arsize=3'($clog2(DATA_W/8));m_axi_arburst=2'b01;
        m_axi_rready=1;read_done_o=m_axi_rvalid && m_axi_rlast;
        read_done_slot_o=L2_SLOT_W'(m_axi_rid);read_data_o=rd_data_q[m_axi_rid];
        read_data_o[rd_beat_q[m_axi_rid]*DATA_W+:DATA_W]=m_axi_rdata;
        read_error_o=rd_err_q[m_axi_rid] || m_axi_rresp!=0;
        m_axi_awvalid=send_valid_q && !aw_done_q;
        m_axi_awid=ID_W'(send_q);m_axi_awaddr=PADDR_W'({wb_addr_q[send_q],6'b0});
        m_axi_awlen=8'(BEATS-1);m_axi_awsize=3'($clog2(DATA_W/8));m_axi_awburst=2'b01;
        m_axi_wvalid=send_valid_q && wbeat_q<BEATS;
        m_axi_wdata=wb_data_q[send_q][(wbeat_q%BEATS)*DATA_W+:DATA_W];
        m_axi_wstrb='1;m_axi_wlast=wbeat_q==BEATS-1;m_axi_bready=1;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            rd_busy_q<='{default:0};rd_err_q<='{default:0};rd_data_q<='{default:'0};rd_beat_q<='{default:0};
            wb_valid_q<='{default:0};wb_sent_q<='{default:0};wb_addr_q<='{default:'0};wb_data_q<='{default:'0};
            send_valid_q<=0;send_q<=0;wbeat_q<=0;aw_done_q<=0;fatal_o<='0;
        end else begin
            if(m_axi_arvalid && m_axi_arready) begin rd_busy_q[read_slot_i]<=1;rd_err_q[read_slot_i]<=0;rd_beat_q[read_slot_i]<=0;end
            if(m_axi_rvalid) begin
                assert(int'(m_axi_rid)<N && rd_busy_q[m_axi_rid]);
                assert(m_axi_rlast==(rd_beat_q[m_axi_rid]==BEATS-1));
                rd_data_q[m_axi_rid][rd_beat_q[m_axi_rid]*DATA_W+:DATA_W]<=m_axi_rdata;
                rd_err_q[m_axi_rid]<=rd_err_q[m_axi_rid] || m_axi_rresp!=0;
                rd_beat_q[m_axi_rid]<=rd_beat_q[m_axi_rid]+1;
                if(m_axi_rlast) rd_busy_q[m_axi_rid]<=0;
            end
            if(wb_push_i) begin
                assert(wb_free_o);wb_valid_q[wb_free_idx]<=1;wb_sent_q[wb_free_idx]<=0;
                wb_addr_q[wb_free_idx]<=wb_addr_i;wb_data_q[wb_free_idx]<=wb_data_i;
            end
            if(!send_valid_q && send_idx>=0) begin send_valid_q<=1;send_q<=send_idx;aw_done_q<=0;wbeat_q<=0;end
            if(m_axi_awvalid && m_axi_awready) aw_done_q<=1;
            if(m_axi_wvalid && m_axi_wready) wbeat_q<=wbeat_q+1;
            if(send_valid_q && (aw_done_q || (m_axi_awvalid && m_axi_awready)) &&
                (wbeat_q==BEATS || (m_axi_wvalid && m_axi_wready && m_axi_wlast))) begin
                send_valid_q<=0;wb_sent_q[send_q]<=1;
            end
            if(m_axi_bvalid) begin
                assert(int'(m_axi_bid)<WN && wb_valid_q[m_axi_bid] && wb_sent_q[m_axi_bid]);
                if(m_axi_bresp!=0) fatal_o<='{valid:1'b1,src:FATAL_L2_WB,line_paddr:PADDR_W'({wb_addr_q[m_axi_bid],6'b0})};
                else wb_valid_q[m_axi_bid]<=0;
            end
            if($past(m_axi_arvalid && !m_axi_arready && !rst)) assert(m_axi_arvalid && $stable({m_axi_arid,m_axi_araddr}));
            if($past(m_axi_awvalid && !m_axi_awready && !rst)) assert(m_axi_awvalid && $stable({m_axi_awid,m_axi_awaddr}));
            if($past(m_axi_wvalid && !m_axi_wready && !rst)) assert(m_axi_wvalid && $stable({m_axi_wdata,m_axi_wlast}));
        end
    end
endmodule
