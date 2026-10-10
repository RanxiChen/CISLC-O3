// Exhaust the default circular index/slot space against the original modulo
// age rule, including valid/all/self controls and matching/stale generations.
module frontend_age_tb;
    import o3_types_pkg::*;
    ftq_id_t head,lhs,rhs;
    fetch_slot_t lhs_slot,rhs_slot;
    fe_kill_t kill;
    int unsigned lhs_age,rhs_age;
    logic expected;
    longint unsigned cases_done;
    initial begin
        cases_done=0;
        for(int h=0;h<FTQ_DEPTH;h++)
        for(int a=0;a<FTQ_DEPTH;a++)
        for(int b=0;b<FTQ_DEPTH;b++)
        for(int sa=0;sa<REGION_SLOTS;sa++)
        for(int sb=0;sb<REGION_SLOTS;sb++) begin
            head='0;head.idx=FTQ_IDX_W'(h);
            lhs='0;lhs.idx=FTQ_IDX_W'(a);lhs.gen=FTQ_GEN_W'(h+a);
            lhs_slot=fetch_slot_t'(sa);rhs_slot=fetch_slot_t'(sb);
            lhs_age=fe_age(lhs,lhs_slot,head);
            for(int flags=0;flags<16;flags++) begin
                rhs='0;rhs.idx=FTQ_IDX_W'(b);
                rhs.gen=lhs.gen+FTQ_GEN_W'((flags>>3)&1);
                rhs_age=fe_age(rhs,rhs_slot,head);
                assert(fe_before(lhs,lhs_slot,rhs,rhs_slot,head)==(lhs_age<rhs_age))
                    else $fatal(1,"circular order h=%0d a=%0d sa=%0d b=%0d sb=%0d",h,a,sa,b,sb);
                kill='{valid:1'(flags&1),all:1'((flags>>1)&1),
                    kill_self:1'((flags>>2)&1),ftq_id:rhs,slot:rhs_slot};
                expected=kill.valid && (kill.all || lhs_age>rhs_age
                    || (kill.kill_self && lhs==rhs && lhs_slot==rhs_slot));
                assert(fe_killed_by(kill,lhs,lhs_slot,head)==expected)
                    else $fatal(1,"circular kill h=%0d a=%0d sa=%0d b=%0d sb=%0d flags=%0d",h,a,sa,b,sb,flags);
                cases_done++;
            end
        end
        $display("FRONTEND_AGE_EXHAUSTIVE_PASS cases=%0d",cases_done);
        $finish;
    end
endmodule
