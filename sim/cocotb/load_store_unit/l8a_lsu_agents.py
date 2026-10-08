"""Module driver with event-driven LQ model and fixed S0/S1/S2 cache contract."""
import cocotb
from l3_contract import codec,field,val,array,clear
from cocotb.triggers import Timer

INPUTS=['atomic_i','heu_valid_i','heu_req_i','clk','rst','mem_uop_i','issue_is_load_i','lq_replay_valid_i','lq_replay_i',
        'sq_replay_valid_i','sq_replay_i','sq_query_block_i','sq_query_forward_valid_i',
        'sq_query_forward_data_i','full_line_busy_i','internal_busy_i','dc_resp_i',
        'load_result_ready_i','exc_ready_i','flush_all_i','resolution_valid_i',
        'resolution_mispredict_i','resolution_tag_i','csr_i','pmp_i']

class Bench:
    def __init__(self,d):
        self.d=d;self.cycle=0;self.reply=[0,0];self.s0=[None,None]
        self.saved={};self.waits={};self.updates=[];self.results=[];self.stores=[];self.requests=[]
        self.error=False;self.exceptions=[];self.block=False;self.forward=False;self.data=0;self.miss=False;self.hold_result=True
        self.d_marks=[];self.d_clears=[];self.ad_wakes=[]

    async def reset(self):
        clear(self.d,[n for n in INPUTS if hasattr(self.d,n)]);self.d.rst.value=1
        # The L5 precise-exception fixture ties these optional MMU ports off.
        for name in ('ptw_req_ready_i','ptw_resp_i','d_done_i','d_exc_i'):
            if hasattr(self.d,name):getattr(self.d,name).value=0
        # M-mode, bare translation, unlocked PMP permits main memory.
        self.d.csr_i.value=3<<(len(self.d.csr_i)-2)
        # The CSR struct starts priv_eff[1:0]; all other fields zero.
        self.d.pmp_i.value=(0x1f<<54)|0x1fffffff
        await self.tick();await self.tick();self.d.rst.value=0
        self.saved.clear();self.waits.clear();self.updates.clear();self.results.clear();self.stores.clear();self.requests.clear();self.exceptions.clear()

    def uop(self,ident,addr=0x80000108,load=True,mask=0,rob=2,lq=1,sq=0,value=0):
        return codec(self.d,'uop',valid=1,instruction_id=ident,rob_idx=rob,lq_idx=lq,sq_idx=sq,
                     dst_preg=7,dst_dom=1,is_load=int(load),is_store=int(not load),
                     mem_size=3,base_value=addr,store_value=value,branch_mask=mask)

    async def tick(self):
        d=self.d;d.clk.value=0
        array(d.dc_resp_i,self.reply)
        array(d.sq_query_block_i,[int(self.block)]*2)
        array(d.sq_query_forward_valid_i,[int(self.forward)]*2)
        array(d.sq_query_forward_data_i,[self.data]*2)
        array(d.load_result_ready_i,[int(not self.hold_result)]*2)
        await Timer(5,unit='ns')
        if hasattr(d,'d_mark_o') and val(d.d_mark_o):self.d_marks.append((self.cycle,val(d.d_idx_o),val(d.d_va_o)))
        if hasattr(d,'d_clear_o') and val(d.d_clear_o):self.d_clears.append((self.cycle,val(d.d_idx_o),val(d.d_va_o)))
        if hasattr(d,'ad_wake_o') and val(d.ad_wake_o):self.ad_wakes.append(self.cycle)
        next_reply=[0,0];next_s0=[None,None]
        for p in range(2):
            if val(d.load_result_o[p]):
                raw=val(d.load_result_o[p])
                if field(d,'result',raw,'valid'):self.results.append((self.cycle,p,raw))
            if val(d.exc_valid_o[p]):self.exceptions.append((self.cycle,p,val(d.exc_rob_idx_o[p]),val(d.exc_o[p])))
            if val(d.sq_execute_valid_o[p]):
                self.stores.append((self.cycle,p,val(d.sq_execute_addr_o[p]),val(d.sq_execute_data_o[p])))
            if val(d.lq_update_valid_o[p]):
                a=val(d.update_o[p]);idx=field(d,'response',a,'lq_tag.idx')
                status=field(d,'response',a,'status');reason=field(d,'response',a,'reason')
                self.updates.append((self.cycle,p,a))
                if status in (1,2):self.waits[idx]=reason
                else:self.waits.pop(idx,None)
            if self.s0[p] is not None:
                q=val(d.dc_s1_o[p]);idx=field(d,'request',q,'lq_tag.idx');gen=field(d,'request',q,'lq_tag.gen')
                exc=field(d,'request',q,'exc');status=0;reason=0
                if exc:status=3
                elif field(d,'request',q,'translation_miss'):status=2;reason=3
                elif field(d,'request',q,'blocked') and not field(d,'request',q,'is_sta'):status=2;reason=1
                elif self.miss and not field(d,'request',q,'is_sta'):status=1;reason=4
                if self.error:
                    status=3;reason=0
                    exc=(1<<70)|((7 if field(d,'request',q,'is_sta') else 5)<<64)|field(d,'request',q,'vaddr')
                data=field(d,'request',q,'forward_data') if field(d,'request',q,'forward_valid') else self.data
                next_reply[p]=codec(d,'response',**{'valid':1,'status':status,'reason':reason,
                                'mshr_id':0,'lq_tag.idx':idx,'lq_tag.gen':gen,'rdata':data,'exc':exc})
            if val(d.dc_req_valid_o[p]):
                req=val(d.dc_req_o[p]);next_s0[p]=req
                self.requests.append((self.cycle,p,field(d,'request',req,'vaddr')))
                if val(d.lq_capture_valid_o[p]):
                    saved=val(d.capture_o[p]);# AG capture owns the complete saved VA/uop.
                    idx=field(d,'request',req,'lq_tag.idx')
                    saved|=codec(d,'replay',**{'tag.idx':idx,'tag.gen':1})
                    self.saved[idx]=saved
        if val(d.flush_all_i):self.saved.clear();self.waits.clear()
        if val(d.resolution_valid_i):
            bit=1<<val(d.resolution_tag_i)
            for idx,saved in list(self.saved.items()):
                uop=field(d,'replay',saved,'uop');mask=field(d,'uop',uop,'branch_mask')
                if val(d.resolution_mispredict_i) and mask&bit:
                    self.saved.pop(idx);self.waits.pop(idx,None)
                else:
                    # Correct resolution clears the dependency in the queue's saved request.
                    umask=val(d.fmt_uop_branch_mask)
                    uop=(uop&~umask)|codec(d,'uop',branch_mask=mask&~bit)
                    saved=(saved&~val(d.fmt_replay_uop))|codec(d,'replay',uop=uop)
                    self.saved[idx]=saved
        d.clk.value=1;await Timer(5,unit='ns')
        self.s0=next_s0;self.reply=next_reply;self.cycle+=1

    async def until(self,pred,limit=100):
        for _ in range(limit):
            if pred():return
            await self.tick()
        assert False,f'cycle={self.cycle} watchdog updates={self.updates[-8:]}'

    async def issue(self,*uops):
        await self.until(lambda: all(val(self.d.issue_ready_o[p]) for p in range(len(uops))))
        array(self.d.mem_uop_i,list(uops)+[0]*(2-len(uops)))
        await self.tick();array(self.d.mem_uop_i,[0,0])

    async def replay(self,idx):
        assert idx in self.saved and idx in self.waits
        await self.until(lambda: val(self.d.lq_replay_ready_o[0]))
        self.d.lq_replay_i[0].value=self.saved[idx];self.d.lq_replay_valid_i[0].value=1
        await self.tick();self.d.lq_replay_valid_i[0].value=0
