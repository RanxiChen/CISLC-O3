"""Public D24 transaction oracle: age, priority, replacement and event pulses."""
import itertools
import random
import cocotb
from cocotb.triggers import Timer
from bpu_model import Records, encode, decode


def request(src, fid, slot, target):
    return dict(valid=1, src=src, ftq_id=fid, slot=slot, target_pc=target,
                hist_inject=src%2, hist_branch_pc=0x1000+src*4,
                hist_target_pc=0x8000+src*8, ras_fix=src+1,
                ras_push_addr=0x9000+src*4)


class Bench:
    def __init__(self,d):
        self.d=d
        self.r=Records(addr=len(d.pc_o), idw=len(d.head_i),
                       rasptr=int(d.ras_ptr_w_o.value),rascnt=int(d.ras_cnt_w_o.value))
        self.depth=int(d.ftq_depth_o.value)
        self.held=None
        self.events=[0]*4
        self.recover_cycles=0

    async def step(self, *, pd=None, slow=None, exec_=None, sys=None, head=0,
                   done=False, done_id=0, rst=False):
        d,r=self.d,self.r
        d.clk_i.value=0
        vals=dict(rst_i=rst,sys_bits_i=encode(r.sys,sys or {}),
            exec_bits_i=encode(r.resolve,exec_ or {}),pd_bits_i=encode(r.req,pd or {}),
            slow_bits_i=encode(r.req,slow or {}),head_i=head,
            history_done_i=done,ras_done_i=done,done_id_i=done_id,
            ckpt_bits_i=encode(r.ras,dict(top_idx=3,count=4,top_addr=0x4560)))
        for n,v in vals.items():getattr(d,n).value=int(v)
        await Timer(1,unit='ns')
        candidates=[]
        if slow and slow.get('valid'):candidates.append(slow)
        if pd and pd.get('valid'):candidates.append(pd)
        if exec_ and exec_.get('valid') and exec_.get('mispredict'):
            candidates.append(dict(valid=1,src=2,ftq_id=exec_['ftq_id'],slot=exec_['slot'],
                target_pc=exec_['redirect_pc'],hist_inject=int(exec_['cfi_type']==1 and exec_['actual_taken']),
                hist_branch_pc=exec_['branch_pc'],hist_target_pc=exec_['actual_target'],
                ras_fix=exec_['ras_action'],ras_push_addr=exec_['branch_pc']+exec_['inst_len'],
                exec_br_valid=int(exec_['cfi_type']==1),exec_br_taken=exec_['actual_taken']))
        def key(q):
            return (((q['ftq_id']%self.depth)-(head%self.depth))%self.depth,q['slot'],-q['src'])
        selected=min(candidates,key=key) if candidates else None
        if sys and sys.get('valid'):
            selected=dict(valid=1,src=3,sys_kind=sys.get('kind',0),ftq_id=sys['ftq_id'],
                          slot=sys['slot'],kill_self=1,target_pc=sys['target_pc'])
        accepted=selected is not None and not rst and (
            selected['src']==3 or self.held is None or key(selected)<key(self.held))
        expected=selected if accepted else self.held
        wanted=decode(r.req,encode(r.req,expected or {}))
        # A new cocotb case shares the DUT state until the reset edge.
        if not rst:
            assert decode(r.req,int(d.winner_bits_o.value))==wanted
        assert int(d.kill_valid_o.value)==int(d.redirect_valid_o.value)==accepted
        assert int(d.kill_all_o.value)==(accepted and selected['src']==3)
        assert int(d.snap_req_o.value)==(accepted and selected['src']!=3)
        assert decode(r.req,int(d.redirect_bits_o.value))==decode(r.req,encode(r.req,selected if accepted else {}))
        if accepted:
            assert int(d.kill_id_o.value)==selected['ftq_id']
            assert int(d.kill_slot_o.value)==selected['slot']
            assert int(d.kill_self_o.value)==selected.get('kill_self',0)
            assert int(d.pc_o.value)==selected['target_pc']
            if selected['src']!=3:assert int(d.snap_id_o.value)==selected['ftq_id']
        increments=[int(getattr(d,n+'_inc_o').value) for n in ('slow','pd','exec','sys')]
        assert increments==[int(accepted and selected['src']==src) for src in range(4)]
        recovery=int(self.held is not None and not rst)
        assert int(d.recover_inc_o.value)==recovery
        self.events=[a+b for a,b in zip(self.events,increments)]
        self.recover_cycles+=recovery
        assert int(d.ckpt_bits_o.value)==vals['ckpt_bits_i']
        d.clk_i.value=1
        if rst:self.held=None
        elif accepted:self.held=selected if selected['src']!=3 else None
        elif self.held and done and done_id==self.held['ftq_id']:self.held=None
        await Timer(1,unit='ns')
        assert int(d.busy_o.value)==(self.held is not None)
        d.clk_i.value=0
        return selected if accepted else None

    async def reset(self):
        await self.step(rst=True)
        self.events=[0]*4
        self.recover_cycles=0


def execution(fid,slot,target,mispredict=1):
    return dict(valid=1,mispredict=mispredict,ftq_id=fid,slot=slot,branch_pc=0x1234,
                inst_len=4,cfi_type=1,ras_action=2,actual_taken=1,
                actual_target=0xA000,redirect_pc=target)


@cocotb.test()
async def four_way_age_ties_and_wrap(d):
    d.clk_i.value=0
    await Timer(1,unit='ns')
    b=Bench(d)
    for head in (0,b.depth-2):
        ids=[((head+n)%b.depth) | (3*b.depth) for n in (0,1,2)]
        for order in itertools.permutations(ids):
            await b.reset()
            await b.step(slow=request(0,order[0],6,0x9000),
                         pd=request(1,order[1],2,0x1000),
                         exec_=execution(order[2],4,0x5000),head=head)
        await b.reset()
        same=ids[1]
        winner=await b.step(slow=request(0,same,4,0x1000),
                           pd=request(1,same,4,0x2000),exec_=execution(same,4,0x3000),head=head)
        assert winner['src']==2
        await b.reset()
        winner=await b.step(slow=request(0,same,4,0x1000),pd=request(1,same,4,0x2000),head=head)
        assert winner['src']==1
        await b.reset()
        winner=await b.step(slow=request(0,ids[0],0,0x1000),
            pd=request(1,ids[1],0,0x2000),exec_=execution(ids[2],0,0x3000),head=head,
            sys=dict(valid=1,kind=2,ftq_id=ids[2],slot=7,target_pc=0x4000))
        assert winner['src']==3 and b.held is None
        await b.reset()
        winner=await b.step(exec_=execution(ids[0],0,0x2000,mispredict=0),head=head)
        assert winner is None
    rng=random.Random(524)
    for _ in range(100):
        await b.reset()
        head=rng.randrange(b.depth)
        fid=lambda: rng.randrange(b.depth)+b.depth*7
        await b.step(slow=request(0,fid(),rng.randrange(8),0x1000),
                     pd=request(1,fid(),rng.randrange(8),0x2000),
                     exec_=execution(fid(),rng.randrange(8),0x3000),head=head)


@cocotb.test()
async def busy_replacement_and_exact_event_counts(d):
    d.clk_i.value=0
    await Timer(1,unit='ns')
    b=Bench(d)
    await b.reset()
    younger,older=3+b.depth,1+b.depth
    await b.step(slow=request(0,younger,6,0x1000))
    # Repeating the captured request does not constitute another acceptance.
    for _ in range(3):await b.step(slow=request(0,younger,6,0x1000))
    assert b.events==[1,0,0,0] and b.recover_cycles==3
    await b.step(pd=request(1,younger,6,0x2000),done=True,done_id=younger)
    assert b.held['src']==1, 'same-position higher priority must replace recovery'
    await b.step(exec_=execution(younger,6,0x3000))
    assert b.held['src']==2
    await b.step(slow=request(0,older,2,0x4000),done=True,done_id=younger)
    assert b.held['ftq_id']==older
    await b.step(done=True,done_id=younger)
    assert b.held is not None, 'stale done ID cannot finish replacement'
    await b.step(exec_=execution(younger,0,0x5000))
    assert b.held['ftq_id']==older
    await b.step(done=True,done_id=older)
    assert b.held is None
    assert b.events==[2,1,1,0] and b.recover_cycles==9
    await b.step(pd=request(1,younger,4,0x6000))
    await b.step(sys=dict(valid=1,kind=0,ftq_id=older,slot=0,target_pc=0x7000))
    assert b.held is None and b.events==[2,2,1,1]
