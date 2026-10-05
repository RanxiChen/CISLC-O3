import os,random
import cocotb
from l3_contract import *
from backend_control_model import program

@cocotb.test()
async def correct_resolution_coincides_with_rename_dispatch_read_retire(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    await reset(d,['clk','fetch_valid_i','instruction_i','pc_i'])
    width=val(d.cfg_width_o);expected=program(width,120)
    sent=retired=0;overlaps=[0]*4;all_four=0;correct=0;holding=False
    for cycle in range(6000):
        if not holding and sent<len(expected) and rng.randrange(5):holding=True
        d.fetch_valid_i.value=holding
        if holding:
            for lane in range(width):
                row=expected[sent+lane];d.pc_i[lane].value=row[0];d.instruction_i[lane].value=row[1]
        await settle()
        fire=holding and val(d.fetch_ready_o)
        assert not val(d.mispredict_o),(seed,cycle,'fall-through prediction')
        if val(d.correct_o):
            correct+=1;progress=val(d.progress_o)
            for bit in range(4):overlaps[bit]+=bool(progress>>bit&1)
            all_four+=progress==15
        assert val(d.commit_valid_o)==val(d.retire_valid_o),(seed,cycle,'U3 actual retirement')
        for lane in range(width):
            if val(d.retire_valid_o)>>lane&1:
                e=expected[retired]
                actual=(val(d.retire_pc_o[lane]),val(d.retire_rd_o[lane]),bool(val(d.retire_write_o)>>lane&1))
                assert actual==(e[0],e[2],e[3]),(seed,cycle,retired,actual,e)
                if e[3]:assert val(d.retire_data_o[lane])==e[4],(seed,cycle,retired,e,val(d.retire_data_o[lane]))
                retired+=1
        await tick(d)
        if fire:sent+=width;holding=False
        if retired==len(expected):break
    assert retired==len(expected),(seed,cycle,sent,retired)
    assert correct==120 and all(overlaps) and all_four>0,(seed,correct,overlaps,all_four)
    d._log.info('seed=%d cycles=%d transactions=%d C=%d C overlap [retire,read,dispatch,rename]=%s all_four=%d',seed,cycle+1,retired,correct,overlaps,all_four)
