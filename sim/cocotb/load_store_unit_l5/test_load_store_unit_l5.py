import os,random
import cocotb
from l3_contract import val,field
from l8a_lsu_agents import Bench

@cocotb.test()
async def precise_errors_and_flush_late_response(d):
    rng=random.Random(int(os.getenv('TEST_SEED','1')))
    for transaction in range(150):
        e=Bench(d);await e.reset()
        store=transaction%2==0;error=transaction%3==0;flush=transaction%5==0
        addr=0x80010000+transaction*8;rob=transaction%val(d.cfg_rob_o)
        e.error=error;e.data=rng.getrandbits(64)
        for _ in range(rng.randrange(1,5)):await e.tick()
        await e.issue(e.uop(transaction,addr=addr,load=not store,rob=rob))
        await e.until(lambda:any(e.reply))
        assert not e.stores and not e.exceptions and not e.results
        if flush:d.flush_all_i.value=1
        await e.tick();d.flush_all_i.value=0
        # Fixed S2 completes now, while the precise exception is retained in FIFO.
        assert bool(e.stores)==(store and not error and not flush)
        if store and not error and not flush:
            assert e.stores[-1][2]==addr
        await e.tick()
        assert bool(e.exceptions)==(error and not flush)
        if error and not flush:
            _,_,gotrob,exc=e.exceptions[-1]
            assert gotrob==rob and (exc>>64)&63==(7 if store else 5)
            assert exc&((1<<64)-1)==addr and exc>>70==1
        assert bool(e.results)==(not store and not error and not flush)
        if not store and not error and not flush:
            assert field(d,'result',e.results[-1][2],'instruction_id')==transaction
            assert field(d,'result',e.results[-1][2],'result')==e.data
        for _ in range(rng.randrange(1,5)):
            await e.tick()
            assert bool(e.exceptions)==(error and not flush)
            assert bool(e.results)==(not store and not error and not flush)

@cocotb.test()
async def older_exception_fifo_survives_m_until_acceptance(d):
    # Both load and STA exceptions are older than the resolving branch.
    for store in (False, True):
        e=Bench(d);await e.reset();e.error=True
        addr=0x80010008
        await e.issue(e.uop(2000,addr=addr,load=not store,rob=2,mask=0))
        await e.until(lambda:val(d.exc_valid_o[0]))
        d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=1
        d.resolution_tag_i.value=0
        await e.tick()
        d.resolution_valid_i.value=0;d.resolution_mispredict_i.value=0
        for _ in range(12):
            assert val(d.exc_valid_o[0]) and val(d.exc_rob_idx_o[0])==2
            exc=val(d.exc_o[0]);assert exc>>70==1
            assert (exc>>64)&63==(7 if store else 5) and exc&((1<<64)-1)==addr
            await e.tick()
        d.exc_ready_i[0].value=1
        await e.tick();d.exc_ready_i[0].value=0
        await e.tick()
        assert not val(d.exc_valid_o[0]) and not e.stores and not e.results
