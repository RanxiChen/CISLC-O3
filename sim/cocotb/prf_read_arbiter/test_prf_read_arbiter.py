import os,random
import cocotb
from ports import INPUTS
from l3_contract import *

@cocotb.test()
async def atomic_age_order_four_ports_backpressure_and_m(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    clear(d,INPUTS);await settle();alus=len(d.alu_regread_ready_i);ports=val(d.cfg_read_ports_o);rob=val(d.cfg_rob_o)
    for cycle in range(800):
        clear(d,INPUTS);head=rng.randrange(rob);block=cycle%11==0
        indices=rng.sample(range(rob),alus+2);candidates=[]
        for n in range(alus+2):
            rs1=rng.randrange(2);rs2=rng.randrange(2);imm=rng.randrange(2)
            ready=bool(rng.randrange(4));valid=bool(rng.randrange(4))
            e=codec(d,'renamed_uop_t',valid=int(valid),rob_idx=indices[n],rs1_read_en=rs1,rs2_read_en=rs2,use_imm=imm,src1_preg=1+2*n,src2_preg=2+2*n)
            reads=[1+2*n] if rs1 else []
            if rs2 and (n>=alus or not imm):reads.append(2+2*n)
            candidates.append((e,valid,ready,reads))
        bundle(d.int_issue_uop_i,[e[0] for e in candidates[:alus]])
        d.int_issue_valid_i.value=sum(int(e[1])<<n for n,e in enumerate(candidates[:alus]))
        array(d.alu_regread_ready_i,[int(e[2]) for e in candidates[:alus]])
        d.mem_issue_uop_i.value=candidates[alus][0];d.mem_issue_valid_i.value=candidates[alus][1];d.mem_accept_i.value=candidates[alus][2]
        d.br_issue_uop_i.value=candidates[-1][0];d.br_issue_valid_i.value=candidates[-1][1];d.branch_regread_ready_i.value=candidates[-1][2]
        d.rob_head_i.value=head;d.issue_block_i.value=block
        expected=[False]*(alus+2);addresses=[]
        for n in sorted(range(alus+2),key=lambda n:(indices[n]-head)%rob):
            _,valid,ready,reads=candidates[n]
            if not block and valid and ready and len(addresses)+len(reads)<=ports:
                expected[n]=True;addresses+=reads
        await settle()
        actual=[bool(val(d.int_read_grant_o)>>n&1) for n in range(alus)]+[bool(val(d.mem_read_grant_o)),bool(val(d.branch_read_grant_o))]
        assert actual==expected,(seed,cycle,head,indices,candidates,actual,expected)
        assert [val(d.prf_rd_addr_o[n]) for n in range(ports)][:len(addresses)]==addresses,(seed,cycle,addresses)
