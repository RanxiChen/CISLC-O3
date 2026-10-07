/** L10 walk cache: upper 1x4, middle 2x4, tree PLRU, accumulated G.
 * N combinational lookup/fill; edge N touches PLRU or installs a nonleaf.
 * N+1 new entry visible. rs1!=x0 fences preserve all nonleaf entries.
 * epoch gates fills; root changes rely on architectural SFENCE, like TLBs.
 * Tests: sim/cocotb/mmu/.
 */
module walk_cache import o3_types_pkg::*; #(parameter o3_cfg_pkg::backend_cfg_t CFG)(
    input logic clk,rst,lookup_valid_i,input logic [SV39_VPN_W-1:0] lookup_vpn_i,input asid_t lookup_asid_i,
    output logic hit_o,output logic [1:0] hit_level_o,output logic [PPN_W-1:0] hit_next_ppn_o,
    output logic hit_global_o,
    input logic fill_valid_i,input logic [SV39_VPN_W-1:0] fill_vpn_i,input asid_t fill_asid_i,
    input logic fill_global_i,input logic [1:0] fill_level_i,input logic [PPN_W-1:0] fill_next_ppn_i,
    input xlate_epoch_t fill_epoch_i,cur_epoch_i,input sfence_req_t sfence_i
);
    initial assert(CFG.mmu.walk_cache_upper_sets==1 && CFG.mmu.walk_cache_upper_ways==4 &&
        CFG.mmu.walk_cache_middle_sets==2 && CFG.mmu.walk_cache_middle_ways==4)
        else $fatal(1,"L10 walk cache organization must match X4");
    typedef struct packed {logic valid;sv39_vpn_t vpn;asid_t asid;logic g;logic[43:0] ppn;} entry_t;
    entry_t upper_q[4],middle_q[2][4];
    logic[2:0] upper_plru_q,middle_plru_q[2];
    int upper_hit,middle_hit,lookup_set,fill_set,victim;
    always_comb begin
        upper_hit=-1;middle_hit=-1;lookup_set=int'(lookup_vpn_i[9]);fill_set=int'(fill_vpn_i[9]);
        for(int w=3;w>=0;w--) begin
            if(upper_q[w].valid && upper_q[w].vpn[26:18]==lookup_vpn_i[26:18] &&
                (upper_q[w].g || upper_q[w].asid==lookup_asid_i)) upper_hit=w;
            if(middle_q[lookup_set][w].valid && middle_q[lookup_set][w].vpn[26:9]==lookup_vpn_i[26:9] &&
                (middle_q[lookup_set][w].g || middle_q[lookup_set][w].asid==lookup_asid_i)) middle_hit=w;
        end
        hit_o=lookup_valid_i && (upper_hit>=0 || middle_hit>=0);hit_level_o=0;hit_next_ppn_o=0;hit_global_o=0;
        if(middle_hit>=0) begin hit_level_o=1;hit_next_ppn_o=middle_q[lookup_set][middle_hit].ppn;hit_global_o=middle_q[lookup_set][middle_hit].g;end
        else if(upper_hit>=0) begin hit_level_o=2;hit_next_ppn_o=upper_q[upper_hit].ppn;hit_global_o=upper_q[upper_hit].g;end
        victim=fill_level_i==2 ? mmu_plru_victim(upper_plru_q) : mmu_plru_victim(middle_plru_q[fill_set]);
        for(int w=3;w>=0;w--) if(fill_level_i==2 ? !upper_q[w].valid : !middle_q[fill_set][w].valid) victim=w;
        // Rewalk may revisit an existing key; replace that key instead of duplicating it.
        for(int w=3;w>=0;w--) if(fill_level_i==2 ?
            (upper_q[w].valid && upper_q[w].vpn[26:18]==fill_vpn_i[26:18] && upper_q[w].asid==fill_asid_i) :
            (middle_q[fill_set][w].valid && middle_q[fill_set][w].vpn[26:9]==fill_vpn_i[26:9] && middle_q[fill_set][w].asid==fill_asid_i)) victim=w;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            upper_plru_q<=0;for(int w=0;w<4;w++) upper_q[w]<='0;
            for(int s=0;s<2;s++) begin middle_plru_q[s]<=0;for(int w=0;w<4;w++) middle_q[s][w]<='0;end
        end else begin
            if(hit_o) begin
                if(middle_hit>=0) middle_plru_q[lookup_set]<=mmu_plru_touch(middle_plru_q[lookup_set],middle_hit);
                else upper_plru_q<=mmu_plru_touch(upper_plru_q,upper_hit);
            end
            if(fill_valid_i && fill_epoch_i==cur_epoch_i && !sfence_i.valid) begin
                if(fill_level_i==2) begin upper_q[victim]<='{valid:1'b1,vpn:fill_vpn_i,asid:fill_asid_i,g:fill_global_i,ppn:fill_next_ppn_i};upper_plru_q<=mmu_plru_touch(upper_plru_q,victim);end
                else begin middle_q[fill_set][victim]<='{valid:1'b1,vpn:fill_vpn_i,asid:fill_asid_i,g:fill_global_i,ppn:fill_next_ppn_i};middle_plru_q[fill_set]<=mmu_plru_touch(middle_plru_q[fill_set],victim);end
            end
            if(sfence_i.valid && sfence_i.rs1_is_x0) begin
                for(int w=0;w<4;w++) if(sfence_i.rs2_is_x0 || (!upper_q[w].g && upper_q[w].asid==sfence_i.asid)) upper_q[w].valid<=0;
                for(int s=0;s<2;s++) for(int w=0;w<4;w++) if(sfence_i.rs2_is_x0 || (!middle_q[s][w].g && middle_q[s][w].asid==sfence_i.asid)) middle_q[s][w].valid<=0;
            end
        end
    end
endmodule
