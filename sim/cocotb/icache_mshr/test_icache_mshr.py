import os,random
import cocotb
from cocotb.triggers import Timer

async def settle():await Timer(1,unit='ns')
async def edge(d):
    d.clk.value=0;await settle();d.clk.value=1;await settle();d.clk.value=0;await settle()

@cocotb.test()
async def full_payload_out_of_order_response_stalls_and_reuse(d):
    seed=int(os.getenv('TEST_SEED','1'))+105;rng=random.Random(seed)
    for n in ['clk','rst','alloc_valid','alloc_addr','req_ready','resp_valid','resp_error','resp_id','resp_data','fill_ready']:getattr(d,n).value=0
    d.rst.value=1;await edge(d);d.rst.value=0
    n=int(d.depth.value)
    for batch in range(80):
        ids=[];payload={};filled={}
        for line in range(n):
            addr=0x80000000+batch*4096+line*64
            d.alloc_addr.value=addr;d.alloc_valid.value=1;await settle()
            assert int(d.alloc_ready.value) and not int(d.alloc_merged.value),(seed,batch,line,'allocation')
            await edge(d);d.alloc_valid.value=0
            for wait in range(20):
                await settle()
                if int(d.req_valid.value):break
                await edge(d)
            else:assert False,(seed,batch,line,'request timeout')
            idx=int(d.req_id.value);assert int(d.req_addr.value)==addr and idx not in ids
            ids.append(idx);payload[idx]=(addr,rng.getrandbits(len(d.fill_data)),rng.randrange(5)==0)
            d.req_ready.value=1;await edge(d);d.req_ready.value=0
            # Same-line merge preserves the occupied physical response owner.
            d.alloc_valid.value=1;await settle();before=int(d.free_count.value)
            assert int(d.alloc_ready.value) and int(d.alloc_merged.value)
            await edge(d);d.alloc_valid.value=0;assert int(d.free_count.value)==before
        assert int(d.free_count.value)==0
        order=list(ids);rng.shuffle(order)
        async def observe():
            await settle();assert int(d.fill_valid.value)==bool(filled),(seed,batch,'fill validity')
            if filled:
                idx=min(filled);a,data,error=filled[idx]
                assert (int(d.fill_addr.value),int(d.fill_data.value),bool(int(d.fill_error.value)))==(a,data,error),(seed,batch,idx,'opaque line')
        for turn,idx in enumerate(order):
            for _ in range(rng.randrange(4)):await observe();await edge(d)
            await observe()
            # Occasionally consume one previous fill while a different response
            # writes RAM at this edge; the pre-edge old payload must still win.
            consume=bool(filled) and turn%2==1
            d.fill_ready.value=int(consume)
            d.resp_valid.value=1;d.resp_id.value=idx;d.resp_data.value=payload[idx][1];d.resp_error.value=int(payload[idx][2])
            await observe();old=min(filled) if consume else None
            await edge(d)
            if old is not None:del filled[old]
            filled[idx]=payload[idx]
            d.resp_valid.value=0;d.fill_ready.value=0
        for _ in range(4):await observe();await edge(d)
        while filled:
            await observe();idx=min(filled);d.fill_ready.value=1
            await edge(d);del filled[idx]
        d.fill_ready.value=0;await observe();assert int(d.free_count.value)==n
        if batch%19==0:
            d.rst.value=1;await edge(d);d.rst.value=0;await observe()
