"""Small independent bit-pattern oracle; no comprehensive IEEE-754 claim."""
import os
import random
import struct
import cocotb
from cocotb.triggers import Timer

def bits(x):return struct.unpack('>Q',struct.pack('>d',x))[0]
def fp_bits(x,fmt):
    if fmt:return bits(x)
    return 0xffffffff00000000 | struct.unpack('>I',struct.pack('>f',x))[0]
def tag_id(d,ident):return ident & ((1 << int(d.rob_width_o.value))-1)
async def settle():await Timer(1,unit='ns')
async def edge(d):
    d.clk.value=0;await settle();d.clk.value=1;await settle();d.clk.value=0;await settle()
async def reset(d):
    for n in ('clk','flush_i','req_valid_i','resp_ready_i','unit_i','op_i','src_fmt_i','dst_fmt_i','int_fmt_i','op_mod_i','rm_i','a_i','b_i','c_i','id_i','mask_i','resolve_i','mispredict_i','branch_i'):
        getattr(d,n).value=0
    d.rst.value=1;await edge(d);d.rst.value=0;await settle()
    assert int(d.resp_valid_o.value)==0 and int(d.busy_o.value)==0
async def send(d,unit,op,a,b=0,c=0,ident=1,mask=0,fmt=1,rm=0):
    for n,v in dict(unit_i=unit,op_i=op,a_i=a,b_i=b,c_i=c,id_i=ident,mask_i=mask,src_fmt_i=fmt,dst_fmt_i=fmt,rm_i=rm).items():getattr(d,n).value=v
    d.req_valid_i.value=1
    for _ in range(200):
        await settle()
        if int(d.req_ready_o.value):
            await edge(d);d.req_valid_i.value=0;return
        await edge(d)
    assert False,'request acceptance timeout'
async def result(d,expected,flags=0,ident=1,mask=0):
    for _ in range(300):
        await settle()
        if int(d.resp_valid_o.value):break
        await edge(d)
    else:assert False,'result timeout'
    observed=lambda:tuple(int(getattr(d,n).value) for n in ('result_o','flags_o','id_o','mask_o'))
    want=(expected,flags,tag_id(d,ident),mask)
    assert observed()==want,(observed(),want)
    for _ in range(5):
        await edge(d)
        assert int(d.resp_valid_o.value)==1 and observed()==want,'unstable backpressured result'
    d.resp_ready_i.value=1;await edge(d);d.resp_ready_i.value=0

@cocotb.test()
async def arithmetic_moves_conversion_and_backpressure(d):
    await reset(d)
    # All four split groups; exact arithmetic avoids host rounding dependence.
    vectors=[(0,0,bits(2),bits(3),0,bits(5),0),
             (0,1,bits(7),bits(2),0,bits(5),0),
             (0,2,bits(2),bits(3),0,bits(6),0),
             (0,3,bits(2),bits(3),bits(4),bits(10),0),
             (1,7,bits(6),bits(2),0,bits(3),0),
             (1,8,bits(9),0,0,bits(3),0),
             (1,7,bits(1),bits(0),0,bits(float('inf')),8),
             (2,14,0x7ff0000000000001,bits(1),0,0,16),
             (2,12,bits(3),bits(2),0,bits(2),0),
             (3,20,3,0,0,bits(3),0),
             (3,19,bits(3),0,0,3,0),
             (3,22,0x7ff0000000000001,0,0,0x7ff0000000000001,0)]
    for ident,(unit,op,a,b,c,want,flags) in enumerate(vectors,1):
        await send(d,unit,op,a,b,c,ident);await result(d,want,flags,ident)
    await send(d,3,22,0x80000001,fmt=0);await result(d,0xffffffff80000001)
    await send(d,3,21,0xffffffff80000001,fmt=0);await result(d,0xffffffff80000001)
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    for ident in range(32):
        a,b=rng.randrange(-32,33),rng.randrange(-32,33)
        await send(d,0,0,bits(a),bits(b),ident=ident)
        await result(d,bits(a+b),ident=ident)

@cocotb.test()
async def branch_and_global_flush_drop_late_results(d):
    await reset(d)
    for global_flush in (False,True):
        await send(d,1,7,bits(7),bits(3),ident=7,mask=2)
        d.flush_i.value=int(global_flush);d.resolve_i.value=int(not global_flush)
        d.mispredict_i.value=1;d.branch_i.value=1
        await settle();assert int(d.resp_valid_o.value)==0
        await edge(d);d.flush_i.value=0;d.resolve_i.value=0;d.mispredict_i.value=0
        for cycle in range(300):
            assert int(d.resp_valid_o.value)==0,('cancelled result escaped',cycle)
            await edge(d)
            if not int(d.busy_o.value):break
        else:assert False,'cancelled identity never drained'
        await send(d,1,7,bits(6),bits(2),ident=7)
        await result(d,bits(3),ident=7)  # slot/ROB identity reuse after drain
    await send(d,3,22,bits(4),ident=8,mask=2)
    for _ in range(20):
        if int(d.resp_valid_o.value):break
        await edge(d)
    assert int(d.resp_valid_o.value)==1
    d.resolve_i.value=1;d.mispredict_i.value=1;d.branch_i.value=1;d.resp_ready_i.value=1
    await settle();assert int(d.resp_valid_o.value)==0  # cancellation wins over WB
    await edge(d);d.resolve_i.value=0;d.mispredict_i.value=0;d.resp_ready_i.value=0
    await edge(d);assert int(d.busy_o.value)==0

async def fma_burst(d,vectors):
    """Accept up to five requests on consecutive edges before any WB release."""
    d.unit_i.value=0;d.resp_ready_i.value=0
    for ident,fmt,op,a,b,c,rm,mask,want,flags in vectors:
        for n,v in dict(op_i=op,a_i=a,b_i=b,c_i=c,id_i=ident,mask_i=mask,
                        src_fmt_i=fmt,dst_fmt_i=fmt,rm_i=rm).items():
            getattr(d,n).value=v
        d.req_valid_i.value=1
        await settle()
        assert int(d.req_ready_o.value)==1,('FMA burst lost II=1 admission',ident,fmt)
        await edge(d)
    d.req_valid_i.value=0

async def drain_fma(d,expected,rng):
    """Mixed S/D responses may reorder; match identities and hold under stalls."""
    expected={tag_id(d,ident):item for ident,item in expected.items()}
    held=None
    for cycle in range(300):
        d.resp_ready_i.value=int(cycle>=5 and rng.randrange(4)!=0)
        await settle()
        valid=int(d.resp_valid_o.value)
        observed=tuple(int(getattr(d,n).value) for n in
                       ('result_o','flags_o','id_o','mask_o'))
        if held is not None:
            assert valid and observed==held,('FMA changed held output',cycle,held,observed)
        if valid:
            data,flags,ident,mask=observed
            assert ident in expected,('unexpected/duplicate FMA response',cycle,observed)
            assert (data,flags,mask)==expected[ident],(cycle,observed,expected[ident])
            if int(d.resp_ready_i.value):
                del expected[ident];held=None
            else:held=observed
        else:held=None
        await edge(d)
        if not expected and not int(d.busy_o.value):
            d.resp_ready_i.value=0
            assert int(d.resp_valid_o.value)==0
            return
    assert False,('FMA pipeline did not drain',expected)

@cocotb.test()
async def fma_overlapping_requests_formats_rounding_and_flags(d):
    await reset(d)
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    # Five accepts while WB is blocked prove multiple requests execute in flight.
    # Keep rounding/flags on each request, including the single-round FMA case.
    for fmt in (0,1):
        enc=lambda x:fp_bits(x,fmt)
        unit=enc(1);next_unit=unit+1
        half_ulp=enc(2.0**(-24 if fmt==0 else -53))
        min_sub=0xffffffff00000001 if fmt==0 else 1
        fused=(0xffffffff3f800001,0xffffffff3f7ffffe,enc(-1),0xffffffffa8800000) if fmt==0 else (
            0x3ff0000000000001,0x3feffffffffffffe,enc(-1),0xb970000000000000)
        vectors=[
            (1,fmt,3,enc(2),enc(3),enc(4),0,0,enc(10),0),
            (2,fmt,0,unit,half_ulp,0,0,0,unit,1),       # RNE tie, NX
            (3,fmt,0,unit,half_ulp,0,3,0,next_unit,1),  # RUP tie, NX
            (4,fmt,2,min_sub,enc(.5),0,0,0,enc(0),3),  # UF after rounding + NX
            (5,fmt,3,*fused[:3],0,0,fused[3],0),       # fused cancellation
        ]
        await fma_burst(d,vectors)
        await drain_fma(d,{v[0]:(v[8],v[9],v[7]) for v in vectors},rng)
    # Exact integer-valued operations form an independent bit-pattern oracle.
    # Alternating formats also checks arbitration returns the matching identity.
    vectors=[]
    for index in range(32):
        fmt=rng.randrange(2);op=rng.randrange(4)
        a,b,c=(rng.randrange(-32,33) for _ in range(3))
        want=(a+b,a-b,a*b,a*b+c)[op]
        rm=rng.randrange(5)
        want_bits=fp_bits(want,fmt)
        if want==0:
            # IEEE exact zero retains multiplication's sign; cancellation is
            # negative only under RDN, including opposite signed zero inputs.
            if op==2:negative=(a<0)!=(b<0)
            elif op==0:negative=rm==2 and (a!=0 or b!=0)
            elif op==1:negative=rm==2
            else:negative=rm==2 and (a*b!=0 or ((a<0)!=(b<0)))
            if negative:want_bits |= 1 << (63 if fmt else 31)
        vectors.append((index+1,fmt,op,fp_bits(a,fmt),fp_bits(b,fmt),fp_bits(c,fmt),
                        rm,0,want_bits,0))
    for offset in range(0,len(vectors),5):
        group=vectors[offset:offset+5]
        await fma_burst(d,group)
        await drain_fma(d,{v[0]:(v[8],v[9],v[7]) for v in group},rng)

@cocotb.test()
async def fma_recovery_with_multiple_pipeline_stages_occupied(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    for fmt in (0,1):
        for recovery in ('resolve','mispredict','flush','reset'):
            await reset(d)
            vectors=[(ident,fmt,3,fp_bits(ident,fmt),fp_bits(2,fmt),fp_bits(1,fmt),
                      0,2 if ident%2 else 0,fp_bits(2*ident+1,fmt),0)
                     for ident in range(1,6)]
            await fma_burst(d,vectors)
            if recovery=='reset':d.rst.value=1
            elif recovery=='flush':d.flush_i.value=1
            else:
                d.resolve_i.value=1;d.branch_i.value=1
                d.mispredict_i.value=int(recovery=='mispredict')
            await edge(d)
            d.rst.value=0;d.flush_i.value=0;d.resolve_i.value=0;d.mispredict_i.value=0
            expected={}
            if recovery in ('resolve','mispredict'):
                expected={v[0]:(v[8],v[9],0) for v in vectors
                          if recovery=='resolve' or not v[7]}
            await drain_fma(d,expected,rng)
            # Reuse the same identity only after the killed computations drain.
            await send(d,0,3,fp_bits(2,fmt),fp_bits(3,fmt),fp_bits(4,fmt),ident=1,fmt=fmt)
            await result(d,fp_bits(10,fmt),ident=1)


@cocotb.test()
async def fma_long_stream_sustains_one_accept_per_cycle(d):
    """A short burst misses credit bubbles after filling the DP pipeline."""
    for fmt in (0,1):
        await reset(d)
        d.unit_i.value=0
        d.resp_ready_i.value=1
        pending={}
        accepted=0
        retired=0
        for cycle in range(140):
            issue=accepted<96
            ident=accepted+1
            if issue:
                for name,value in dict(op_i=3,a_i=fp_bits(2,fmt),b_i=fp_bits(3,fmt),
                                       c_i=fp_bits(ident,fmt),id_i=ident,mask_i=0,
                                       src_fmt_i=fmt,dst_fmt_i=fmt,rm_i=0).items():
                    getattr(d,name).value=value
            d.req_valid_i.value=int(issue)
            await settle()
            if int(d.resp_valid_o.value):
                completed=int(d.id_o.value)
                assert completed in pending,('duplicate or unknown stream result',fmt,cycle,completed)
                assert int(d.result_o.value)==pending.pop(completed),(fmt,cycle,completed)
                assert int(d.flags_o.value)==0,(fmt,cycle,completed,'unexpected flags')
                retired+=1
            if issue:
                assert int(d.req_ready_o.value)==1,('steady II=1 credit bubble',fmt,cycle,accepted)
                actual_id=tag_id(d,ident)
                assert actual_id not in pending,('test reused live ROB identity',fmt,cycle,actual_id)
                pending[actual_id]=fp_bits(6+ident,fmt)
                accepted+=1
            await edge(d)
            if retired==96:
                assert not pending and accepted==96
                break
        else:
            assert False,('continuous FMA stream failed to drain',fmt,accepted,retired,pending)

@cocotb.test()
async def local_completion_credit_and_recovery(d):
    """Two captures under blocked W0; registered credit ignores current ready."""
    for mode in ('none','resolve','head_kill','tail_kill','both_kill','flush','reset'):
        await reset(d)
        d.unit_i.value=3;d.op_i.value=22;d.src_fmt_i.value=1;d.dst_fmt_i.value=1
        masks=[2 if mode in ('head_kill','both_kill','resolve') else 0,
               2 if mode in ('tail_kill','both_kill','resolve') else 0,0]
        notifications=[]
        for cycle in range(12):
            issue=cycle<3
            if issue:
                d.id_i.value=cycle+1;d.a_i.value=0x0123456789000000+cycle
                d.mask_i.value=masks[cycle]
            d.req_valid_i.value=int(issue)
            await settle()
            if issue:assert int(d.req_ready_o.value),('FMV admission bubble',mode,cycle)
            if int(d.wake_valid_o.value):notifications.append(int(d.wake_preg_o.value))
            if cycle>=2:
                assert int(d.resp_valid_o.value),('lost stalled completion',mode,cycle)
                assert int(d.id_o.value)==tag_id(d,1)
                assert int(d.result_o.value)==0x0123456789000000
            await edge(d)
        assert notifications==[1,2],('local completion credits',mode,notifications)
        # Toggling W0 acceptance without an edge cannot lend full-buffer credit.
        d.resp_ready_i.value=1;await settle()
        assert not int(d.wake_valid_o.value),('current W0 ready leaked into wake',mode)
        d.resp_ready_i.value=0;await settle()
        assert not int(d.wake_valid_o.value)
        if mode=='reset':d.rst.value=1
        elif mode=='flush':d.flush_i.value=1
        elif mode!='none':
            d.resolve_i.value=1;d.branch_i.value=1
            d.mispredict_i.value=int(mode!='resolve')
        await edge(d)
        d.rst.value=0;d.flush_i.value=0;d.resolve_i.value=0;d.mispredict_i.value=0
        expected={tag_id(d,i+1):(0x0123456789000000+i,0,
            0 if mode=='resolve' else masks[i]) for i in range(3)
            if mode not in ('reset','flush') and
            not (mode in ('head_kill','tail_kill','both_kill') and masks[i])}
        observed=[]
        d.resp_ready_i.value=1
        for cycle in range(40):
            await settle()
            if int(d.resp_valid_o.value):
                ident=int(d.id_o.value)
                assert ident in expected,('cancelled/duplicate completion',mode,cycle,ident)
                want=expected.pop(ident)
                got=tuple(int(getattr(d,n).value) for n in ('result_o','flags_o','mask_o'))
                assert got==want,(mode,cycle,got,want)
                observed.append(ident)
            await edge(d)
            if not int(d.busy_o.value):
                assert not expected,(mode,'missing completions',expected)
                break
        else:assert False,(mode,'local owners failed to drain')
        assert observed==sorted(observed),(mode,'local completion order',observed)
        # Reuse an identity after both local/native owners have drained.
        await send(d,3,22,0x8877665544332211,ident=1)
        d.resp_ready_i.value=0
        await result(d,0x8877665544332211,ident=1)
