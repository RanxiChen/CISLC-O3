"""External ownership/data oracle for W0->W1; functional run deferred."""
import os, random
import cocotb
from cocotb.triggers import Timer

async def settle():
    await Timer(1, unit='ns')

def packed(values, width):
    return sum(v << (width*n) for n,v in enumerate(values))

class Bench:
    def __init__(self, d):
        self.d=d;w=int(d.widths_o.value)
        self.mw=w&255;self.pw=(w>>8)&255;self.rw=(w>>16)&255
        self.depth=(w>>24)&255;self.ports=(w>>32)&255;self.sources=(w>>40)&255
        self.sw=max(1,(self.sources-1).bit_length());self.rows=[];self.accepted=0;self.completed=0;self.cycle=0
    def put(self, n, v): getattr(self.d,n).value=v
    def get(self, n): return int(getattr(self.d,n).value)
    def item(self, n, s, w): return (self.get(n)>>(s*w))&((1<<w)-1)
    def packet(self, rng, ident, writing=True):
        owners=rng.sample(range(self.sources), min(self.ports,self.sources)) if writing else []
        entries=[]
        for s in range(self.sources):
            valid=s in owners or rng.random()<.35
            entries.append(dict(valid=valid,write=s in owners,rob=(ident+s)% (1<<self.rw),preg=1+(ident+s)%((1<<self.pw)-1),
                mask=rng.randrange(1<<self.mw),data=rng.getrandbits(64),flags=rng.randrange(32)))
        return dict(entries=entries,owners=owners)
    async def tick(self, packet=None, ready=None, resolution=None, flush=False, reset=False):
        ready=[True]*self.ports if ready is None else ready
        resolution=(False,False,0) if resolution is None else resolution
        rv,rm,rt=resolution
        self.put('clk',0);self.put('rst',int(reset));self.put('flush_i',int(flush))
        self.put('resolution_valid_i',int(rv));self.put('resolution_mispredict_i',int(rm));self.put('resolution_tag_i',rt)
        empty=[dict(valid=False,write=False,rob=0,preg=0,mask=0,data=0,flags=0) for _ in range(self.sources)]
        entries=packet['entries'] if packet else empty;owners=packet['owners'] if packet else []
        for signal,key,width in [('src_valid_i','valid',1),('src_write_i','write',1),('src_rob_i','rob',self.rw),('src_preg_i','preg',self.pw),
                                  ('src_mask_i','mask',self.mw),('src_data_i','data',64),('src_flags_i','flags',5)]:
            self.put(signal,packed([int(e[key]) for e in entries],width))
        self.put('write_i',(1<<len(owners))-1);self.put('write_source_i',packed(owners+[0]*(self.ports-len(owners)),self.sw))
        self.put('port_ready_i',packed([int(x) for x in ready],1))
        await settle()
        admit=not reset and not flush and len(self.rows)<self.depth
        assert self.get('admit_o')==admit,('admit',self.cycle,len(self.rows))
        assert self.get('busy_o')==bool(self.rows),('busy',self.cycle)
        # Abstract ordered packets, without modelling physical storage indices.
        live=[];done=set();writes=[]
        if self.rows and not (flush or reset):
            row=self.rows[0]
            for s,e in enumerate(row['entries']):
                valid=e['valid'] and not (rv and rm and e['mask']>>rt&1)
                live.append(valid)
                ports=[p for p,owner in enumerate(row['owners']) if owner==s]
                complete=valid and all(ready[p] for p in ports)
                if complete:done.add(s)
                assert self.item('complete_o',s,1)==complete,('complete',self.cycle,s)
                if complete:
                    for signal,key,width in [('complete_rob_o','rob',self.rw),('complete_preg_o','preg',self.pw),('complete_data_o','data',64),('complete_flags_o','flags',5)]:
                        assert self.item(signal,s,width)==e[key],(signal,self.cycle,s)
                    assert self.item('complete_mask_o',s,self.mw)==(e['mask']&~((1<<rt) if rv else 0)),('mask',self.cycle,s)
            for p in range(self.ports):
                valid=p<len(row['owners']) and live[row['owners'][p]] and ready[p]
                writes.append(valid)
                bypass=p<len(row['owners']) and live[row['owners'][p]]
                assert self.item('bypass_o',p,1)==bypass,('bypass',self.cycle,p)
                if bypass:
                    e=row['entries'][row['owners'][p]]
                    assert self.item('bypass_data_o',p,64)==e['data'],('data bypass',self.cycle,p)
                    assert self.item('addr_o',p,self.pw)==e['preg'],('held owner',self.cycle,p)
                assert self.item('write_o',p,1)==valid,('write',self.cycle,p)
                if valid:
                    e=row['entries'][row['owners'][p]]
                    assert self.item('addr_o',p,self.pw)==e['preg'] and self.item('data_o',p,64)==e['data'],('write packet',self.cycle,p)
        else:
            assert not self.get('complete_o') and not self.get('write_o') and not self.get('bypass_o'),('empty/cancel',self.cycle)
        self.put('clk',1);await settle();self.put('clk',0);await settle()
        if reset or flush:self.rows=[]
        else:
            for row in self.rows:
                for e in row['entries']:
                    if rv and rm and e['mask']>>rt&1:e['valid']=False
                    if rv:e['mask']&=~(1<<rt)
            if self.rows:
                for s in done:self.rows[0]['entries'][s]['valid']=False
                self.completed+=len(done)
                if not any(e['valid'] for e in self.rows[0]['entries']):self.rows.pop(0)
            if packet and admit:
                new=dict(entries=[dict(e) for e in entries],owners=list(owners))
                for e in new['entries']:
                    if rv and rm and e['mask']>>rt&1:e['valid']=False
                    if rv:e['mask']&=~(1<<rt)
                if any(e['valid'] for e in new['entries']):self.rows.append(new);self.accepted+=1
        self.cycle+=1
        return admit,writes

@cocotb.test()
async def continuous_reserved_ports_cancel_and_identity_reuse(d):
    await settle();b=Bench(d);rng=random.Random(int(os.getenv('TEST_SEED','105')))
    await b.tick(reset=True);await b.tick(reset=True)
    # Continuous normal bandwidth: every cycle admits one whole packet and,
    # after the first registered boundary, writes every configured port.
    for cycle in range(96):
        packet=b.packet(rng,cycle);packet['owners']=list(range(min(b.sources,b.ports)))
        for s,e in enumerate(packet['entries']):e['valid']=True;e['write']=s<len(packet['owners']);e['mask']=0
        admit,writes=await b.tick(packet)
        assert admit and (cycle==0 or all(writes)),('continuous throughput',cycle)
    while b.rows:await b.tick()
    # Reserve port0 (CSR) while independent writes/nonwriting completions finish.
    packet=b.packet(rng,1000);packet['owners']=list(range(min(b.sources,b.ports)))
    for s,e in enumerate(packet['entries']):e['valid']=True;e['write']=s<len(packet['owners']);e['mask']=0
    await b.tick(packet,ready=[False]+[True]*(b.ports-1))
    for cycle in range(12):
        await b.tick(b.packet(rng,1100+cycle),ready=[False]+[True]*(b.ports-1))
    assert len(b.rows)==b.depth and not b.get('admit_o')
    while b.rows:await b.tick()
    # Independently randomized packet data, sparse nonwriters, partial grants,
    # correct/mispredict resolution, all rows occupied, global flush and reset.
    for cycle in range(1500):
        rv=rng.random()<.13;rm=rng.random()<.5;rt=rng.randrange(b.mw)
        packet=b.packet(rng,cycle+2000,writing=rng.random()<.9) if rng.random()<.8 else None
        ready=[rng.random()>.35 for _ in range(b.ports)]
        await b.tick(packet,ready,(rv,rm,rt),flush=rng.random()<.012,reset=cycle in (499,999))
    while b.rows:await b.tick()
    assert b.accepted>400 and b.completed>500,(b.accepted,b.completed)
