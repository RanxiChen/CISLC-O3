"""Real L1D/L2 integration, independent architectural and AXI memories."""
import os
import sys
import random
from collections import deque
from pathlib import Path
from cocotb.triggers import Timer
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'dcache'))
from l8a_agents import *
from mem_agents import req, response, READ, READDATA


class SystemBench(CacheBench):
    def __init__(self, dut, seed):
        super().__init__(dut)
        self.seed = seed
        self.rng = random.Random(seed)
        self.l2sets = int(os.environ['L2_SETS'])
        self.l2ways = int(os.environ['L2_WAYS'])
        self.readq = {}
        self.rhold = None
        self.awq, self.wq, self.bq = deque(), deque(), deque()
        self.bhold = None
        self.ipresent = None
        self.iout = {}
        self.i_script = deque()
        self.history = {}
        self.puts = {}
        self.probe_pending = None
        self.loads_done = self.stas_done = self.stores_done = self.i_done = 0
        self.axi_reads = self.axi_writes = 0
        self.reason_counts = {}
        self.trace = deque(maxlen=40)

    async def reset(self):
        d = self.d
        for name in ('cpu_valid','cpu0','cpu1','s1_cpu0','s1_cpu1','rob_head_i','flush_i',
                     'resolution_valid_i','resolution_mispredict_i','resolution_tag_i','st_req_valid_i',
                     'st_req_i','ptw_req_valid_i','ptw_req_i','pte_ad_req_valid_i','pte_ad_req_i',
                     'cur_epoch_i','pmp_i','l1i_req_valid_i','l1i_req_i',
                     'm_axi_awready','m_axi_wready','m_axi_bvalid','m_axi_bid','m_axi_bresp',
                     'm_axi_arready','m_axi_rvalid','m_axi_rid','m_axi_rdata','m_axi_rresp','m_axi_rlast'):
            getattr(d, name).value = 0
        d.dma_req_valid_i.value = 0
        d.dma_req_i.value = 0
        d.dma_resp_ready_i.value = 1
        d.l1i_resp_ready_i.value = 1
        d.pmp_i.value = (0x1f << 54) | 0x1fffffff
        d.rst.value = 1
        for _ in range(3):
            d.clk.value = 0
            await Timer(5, unit='ns')
            d.clk.value = 1
            await Timer(5, unit='ns')
        d.clk.value = 0
        d.rst.value = 0
        await Timer(1, unit='ns')
        v = int(d.widths.value)
        self.widths = [(v >> x) & 255 for x in (24,16,8,0)]
        await self.until(lambda: int(d.init_done.value) and int(d.l2_init_done.value), max(self.sets,self.l2sets)+10)

    def check(self, condition, message):
        assert condition, f'seed={self.seed} cycle={self.cycle} {message}; recent={list(self.trace)}'

    def note(self, *args):
        self.trace.append((self.cycle,*args))
        self.events.append((self.cycle,*args))

    def golden_line(self, line):
        return self.gold.get(line, self.initial(line))

    async def tick(self):
        d = self.d
        d.clk.value = 0
        d.cpu_valid.value = sum((r is not None) << p for p,r in enumerate(self.cpu))
        for p in range(2):
            getattr(d,'cpu'+str(p)).value = self.req_bits(self.cpu[p])
            getattr(d,'s1_cpu'+str(p)).value = self.req_bits(self.prev_cpu[p])
        for name,r in (('st',self.st),('ptw',self.ptw)):
            getattr(d,name+'_req_valid_i').value = int(r is not None)
            getattr(d,name+'_req_i').value = self.req_bits(r)
        d.pte_ad_req_valid_i.value = int(self.ad is not None)
        if self.ad:
            d.pte_ad_req_i.value = pack(*zip((56,64,1,1,8), self.ad))
        if self.ipresent is None and self.i_script and len(self.iout)<4:
            tid = next(i for i in range(4) if i not in self.iout)
            self.ipresent = (tid, self.i_script.popleft(), self.cycle)
        d.l1i_req_valid_i.value = int(self.ipresent is not None)
        if self.ipresent:
            tid,line,_ = self.ipresent
            d.l1i_req_i.value = req(READ,line,tid)
        for name in ('ar','aw','w'):
            getattr(d,'m_axi_'+name+'ready').value = int(self.rng.random()<.7)
        if self.rhold is None and self.rng.random()<.7:
            ids = [k for k,t in self.readq.items() if t[3]<=self.cycle]
            if ids:
                rid = self.rng.choice(ids)
                line,data,beat,_ = self.readq[rid]
                self.rhold = (rid,(data>>(128*beat))&((1<<128)-1),int(beat==3))
        d.m_axi_rvalid.value = int(self.rhold is not None)
        d.m_axi_rresp.value = 0
        if self.rhold:
            rid,data,last = self.rhold
            d.m_axi_rid.value = rid;d.m_axi_rdata.value = data;d.m_axi_rlast.value = last
        if self.bhold is None and self.bq and self.bq[0][0]<=self.cycle:
            self.bhold = self.bq.popleft()[1]
        d.m_axi_bvalid.value = int(self.bhold is not None)
        d.m_axi_bid.value = self.bhold or 0;d.m_axi_bresp.value = 0
        self.drive_extra()
        await Timer(5, unit='ns')
        names = ('cpu_ready','resp0','resp1','st_req_ready_o','st_resp_o','ptw_req_ready_o','ptw_resp_o',
                 'wake_o','l2_req_valid_o','l2_req_ready_i','l2_req_o','l2_resp_valid_i','l2_resp_i',
                 'l2_resp_ready_o','rsp_up_valid_o','rsp_up_ready_i','rsp_up_o','snp_valid_i','snp_ready_o',
                 'snp_i','fatal_o','l2_fatal_o','l1i_req_ready_o','l1i_resp_valid_o','l1i_resp_o',
                 'm_axi_arvalid','m_axi_arready','m_axi_araddr','m_axi_arid','m_axi_arlen','m_axi_arsize','m_axi_arburst',
                 'm_axi_awvalid','m_axi_awready','m_axi_awaddr','m_axi_awid','m_axi_awlen','m_axi_awsize','m_axi_awburst',
                 'm_axi_wvalid','m_axi_wready','m_axi_wdata','m_axi_wstrb','m_axi_wlast','m_axi_rready','m_axi_bready',
                 'pte_ad_req_ready_o','pte_ad_resp_o')
        v = {n:int(getattr(d,n).value) for n in names}
        self.check(not v['fatal_o'] and not v['l2_fatal_o'], 'fatal event')
        if int(d.init_done.value) and int(d.l2_init_done.value):
            self.check(v['rsp_up_ready_i'] and v['l2_resp_ready_o'], 'response channel not unconditional')
        for p,r in enumerate(self.cpu):
            if r:
                self.check(v['cpu_ready']>>p&1, 'IS reservation violated')
        for p in range(2):
            r = self.resp_fields(v['resp'+str(p)])
            if r['valid']:
                self.responses.append((self.cycle,p,r))
                self.note('cpu',p,r['ident'],r['status'],r['reason'])
        for key,dest in (('st_resp_o',self.st_responses),('ptw_resp_o',self.ptw_responses)):
            r = self.resp_fields(v[key])
            if r['valid']:
                dest.append((self.cycle,r))
        if v['pte_ad_resp_o'] & 8:
            self.ad_responses.append((self.cycle,v['pte_ad_resp_o']))
        w = unpack(v['wake_o'], [('valid',1),('mshr',2),('err',1),('free',1),('wb_free',1)])
        if v['wake_o']:
            self.wakes.append((self.cycle,w))
            self.note('wake',w)
        channels = [('req',v['l2_req_valid_o'],v['l2_req_ready_i'],(v['l2_req_o'],)),
                    ('up',v['rsp_up_valid_o'],v['rsp_up_ready_i'],(v['rsp_up_o'],)),
                    ('snp',v['snp_valid_i'],v['snp_ready_o'],(v['snp_i'],))]
        for prefix in ('ar','aw','w'):
            fs = ('id','addr','len','size','burst') if prefix!='w' else ('data','strb','last')
            channels.append((prefix,v['m_axi_'+prefix+'valid'],v['m_axi_'+prefix+'ready'],tuple(v['m_axi_'+prefix+f] for f in fs)))
        for name,valid,ready,bits in channels:
            if name in self.stalled:
                self.check(valid and self.stalled[name]==bits, f'{name} changed while stalled')
            if valid and not ready:self.stalled[name]=bits
            else:self.stalled.pop(name,None)
        # Handshake observer: permissions change only at real wire events.
        if v['l2_resp_valid_i']:
            op,tid,err,data = response(v['l2_resp_i'])
            self.check(not err, 'unexpected refill error')
            if op==PUTACK:
                self.check(tid in self.puts, 'unmatched PutAck')
                del self.puts[tid]
                self.note('putack',tid)
            else:
                self.check(tid in self.sent, 'unmatched grant')
                line,getop = self.sent.pop(tid)
                self.check(op in (DATAS,DATAE,ACKE) and (getop!=GETM or op!=DATAS), 'wrong grant')
                old = self.held.get(line)
                self.check(old=='S' if op==ACKE else old is None, 'SWMR grant permission')
                if op!=ACKE:self.check(data==self.golden_line(line), f'grant golden mismatch line={line:x}')
                self.held[line] = 'S' if op==DATAS else 'X'
                self.note('grant',op,line,tid)
        if v['l1i_resp_valid_o']:
            op,tid,err,data = response(v['l1i_resp_o'])
            self.check(op==READDATA and not err and tid in self.iout, 'bad I response')
            line,start = self.iout.pop(tid)
            hist = self.history.get(line,[])
            prior = [x for c,x in hist if c<=start]
            legal = [prior[-1] if prior else self.initial(line)] + [x for c,x in hist if start<c<=self.cycle]
            self.check(data in legal, f'I golden mismatch line={line:x}')
            self.check(self.held.get(line)!='X', 'I response before DownAck')
            self.i_done += 1
        if v['rsp_up_valid_o']:
            q = unpack(v['rsp_up_o'], [('op',2),('dirty',1),('line',26),('tid',2),('data',512)])
            op,line,tid = q['op'],q['line'],q['tid']
            self.up.append((self.cycle,q))
            if q['dirty']:
                self.check(self.held.get(line)=='X', 'dirty answer without owner')
                self.check(q['data']==self.golden_line(line), f'dirty payload mismatch line={line:x}')
            if op==0:
                self.check(line in self.held and tid not in self.puts, 'Put permission/credit')
                self.held.pop(line);self.puts[tid]=line
            else:
                self.check(self.probe_pending is not None and self.probe_pending[2]==line, 'answer without SNP')
                self.check(op==(1 if self.probe_pending[0]==0 else 2), 'wrong SNP answer')
                if op==1:self.held.pop(line,None)
                elif line in self.held:self.held[line]='S'
                self.probe_pending=None
            self.note('up',op,line,q['dirty'])
        if v['snp_valid_i'] and v['snp_ready_o']:
            raw = v['snp_i'];line=raw&((1<<26)-1);owner=(raw>>27)&1;op=raw>>28
            self.check(self.probe_pending is None, 'multiple SNP in flight')
            self.probe_pending=(op,owner,line)
            self.note('snp',op,owner,line)
        if v['l2_req_valid_o'] and v['l2_req_ready_i']:
            q = unpack(v['l2_req_o'], [('op',2),('line',26),('tid',2),('mask',64),('data',512)])
            op,line,tid = q['op'],q['line'],q['tid']
            self.check(op in (GETS,GETM) and tid not in self.sent and len(self.sent)<self.n, 'Get credits')
            self.check(self.held.get(line) is None if op==GETS else self.held.get(line)!='X', 'Get permission')
            self.check(line not in self.puts.values(), 'Get before PutAck')
            self.sent[tid]=(line,op)
            self.note('get',op,line,tid)
        if self.ipresent and v['l1i_req_ready_o']:
            tid,line,start = self.ipresent
            self.iout[tid]=(line,start);self.ipresent=None
        if v['m_axi_arvalid'] and v['m_axi_arready']:
            rid,addr = v['m_axi_arid'],v['m_axi_araddr']
            self.check(rid not in self.readq and addr%64==0 and (v['m_axi_arlen'],v['m_axi_arsize'],v['m_axi_arburst'])==(3,4,1), 'AR shape/credit')
            line = addr>>6
            self.readq[rid]=(line,self.mem.get(line,self.initial(line)),0,self.cycle+self.rng.randrange(1,13))
            self.axi_reads+=1
        if self.rhold and v['m_axi_rready']:
            rid,_,last = self.rhold
            line,data,beat,due = self.readq[rid]
            if last:del self.readq[rid]
            else:self.readq[rid]=(line,data,beat+1,due)
            self.rhold=None
        if v['m_axi_awvalid'] and v['m_axi_awready']:
            self.check((v['m_axi_awlen'],v['m_axi_awsize'],v['m_axi_awburst'])==(3,4,1), 'AW shape')
            self.awq.append((v['m_axi_awid'],v['m_axi_awaddr']>>6))
        if v['m_axi_wvalid'] and v['m_axi_wready']:
            self.check(v['m_axi_wstrb']==0xffff, 'W strobe')
            self.wq.append((v['m_axi_wdata'],v['m_axi_wlast']))
        if self.awq and len(self.wq)>=4:
            wid,line = self.awq.popleft();beats=[self.wq.popleft() for _ in range(4)]
            self.check([last for _,last in beats]==[0,0,0,1], 'WLAST')
            self.mem[line]=sum(value<<(128*i) for i,(value,_) in enumerate(beats))
            self.bq.append((self.cycle+self.rng.randrange(2,15),wid));self.axi_writes+=1
        if self.bhold is not None and v['m_axi_bready']:self.bhold=None
        if self.st and v['st_req_ready_o']:self.st=None
        if self.ptw and v['ptw_req_ready_o']:self.ptw=None
        if self.ad and v['pte_ad_req_ready_o']:self.ad=None
        self.sample_extra()
        self.prev_cpu=list(self.cpu);self.cpu=[None,None]
        d.clk.value=1
        await Timer(5,unit='ns')
        self.cycle+=1
        self.directory_check()
        return v

    def drive_extra(self):
        pass

    def sample_extra(self):
        pass

    def directory_check(self):
        d=self.d
        valid,states,sharer,addrs = [int(getattr(d,'l2_mon_'+n).value) for n in ('valid','state','sharer','addr')]
        seen=set()
        for k in range(self.l2sets*self.l2ways):
            state=(states>>(2*k))&3;share=(sharer>>k)&1
            self.check((state==0)==(share==0) and state<3, 'directory state/sharer')
            if valid>>k&1:
                line=(addrs>>(26*k))&((1<<26)-1)
                self.check(line not in seen, 'duplicate L2 tag');seen.add(line)

    async def loads(self, requests):
        # LQ semantics: a reason waits for its event after the S2 response.
        waiting = {r.ident:(r,None,-1) for r in requests}
        start_cycle=self.cycle
        while waiting:
            self.check(self.cycle-start_cycle<5000, f'load watchdog waiters={waiting}')
            ready=[]
            for ident,(r,answer,since) in waiting.items():
                wakes=[w for c,w in self.wakes if c>=since]
                if answer is None or (answer['status']==MISS and any(w['valid'] and w['mshr']==answer['mshr'] for w in wakes)) or (answer['status']==REPLAY and (
                    answer['reason'] in (CONFLICT,SNAP,BANK) or
                    (answer['reason']==FULL and any(w['free'] for w in wakes)) or
                    (answer['reason']==WB_LINE and any(w['wb_free'] for w in wakes)))):
                    ready.append(r)
            if not ready:
                await self.tick();continue
            answers=await self.issue(*ready)
            for r,a in zip(ready,answers):
                if a['status']==OK:
                    self.check(a['data']==self.golden(r.addr), f'load golden addr={r.addr:x} actual={a["data"]:x} expected={self.golden(r.addr):x}')
                    self.loads_done+=1;del waiting[r.ident]
                else:
                    self.check(a['status'] in (MISS,REPLAY), 'load exception')
                    self.reason_counts[a['reason']]=self.reason_counts.get(a['reason'],0)+1
                    s2_cycle = next(c for c,p,x in reversed(self.responses) if x["ident"] == r.ident)
                    waiting[r.ident]=(r,a,s2_cycle)

    async def sta(self, r):
        for _ in range(100):
            a=(await self.issue(r))[0]
            if a['status']==OK:
                self.stas_done+=1;return
            self.check(a['status']==REPLAY and a['reason'] in (CONFLICT,SNAP,BANK), 'STA must not wait on ownership')
        self.check(False,'STA watchdog')

    async def store(self, addr, data, mask=255, ident=1):
        a=await super().store(addr,data,mask,ident)
        self.check(a['status']==OK,'store exception')
        self.stores_done+=1
        self.history.setdefault(addr>>6,[]).append((self.cycle-1,self.golden_line(addr>>6)))
        return a

    def quiet(self):
        return (int(self.d.idle_o.value) and not self.sent and not self.puts and self.probe_pending is None and
                not self.i_script and self.ipresent is None and not self.iout and not self.readq and self.rhold is None and
                not self.awq and not self.wq and not self.bq and self.bhold is None and not int(self.d.l2_mon_slot_busy.value))

    async def finish(self):
        await self.until(self.quiet,5000)
        # Exact physical copies and directory correspondence after transit drains.
        directory={};states=int(self.d.l2_mon_state.value);addrs=int(self.d.l2_mon_addr.value);valid=int(self.d.l2_mon_valid.value)
        for k in range(self.l2sets*self.l2ways):
            if valid>>k&1 and (states>>(2*k))&3:
                directory[(addrs>>(26*k))&((1<<26)-1)]='S' if (states>>(2*k))&3==1 else 'X'
        copies={};states=int(self.d.mon_state.value);addrs=int(self.d.mon_addr.value)
        for k in range(self.sets*self.ways):
            state=(states>>(2*k))&3
            if state:
                line=(addrs>>(26*k))&((1<<26)-1)
                self.check(line not in copies,'duplicate L1D tag')
                copies[line]='S' if state==1 else 'X'
        self.check(directory==self.held==copies,f'exact directory/permission/copy mismatch {directory} / {self.held} / {copies}')
        for line in sorted(self.gold):
            await self.loads([Cpu(line<<6)])
        await self.until(self.quiet,5000)
        self.d._log.info('M3 seed=%d cycles=%d loads=%d STA=%d drains=%d I_Read=%d AXI_reads=%d AXI_writes=%d reasons=%s',
                         self.seed,self.cycle,self.loads_done,self.stas_done,self.stores_done,self.i_done,self.axi_reads,self.axi_writes,self.reason_counts)
