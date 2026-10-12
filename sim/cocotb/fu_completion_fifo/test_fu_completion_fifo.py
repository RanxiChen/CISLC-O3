import cocotb
from cocotb.triggers import Timer
async def settle(): await Timer(1,unit="ns")
async def edge(d):
    d.clk.value=0;await settle();d.clk.value=1;await settle();d.clk.value=0;await settle()

@cocotb.test()
async def credits_backpressure_and_wake(d):
    for n in ['clk','rsv_i','pair_i','enq_i','enq_pair_i','consume_i','kill_i','correct_i','release_i','data_i','data2_i','mask_i','mask2_i']:getattr(d,n).value=0
    d.rst.value=1;await edge(d);d.rst.value=0
    d.rsv_i.value=1;d.pair_i.value=1;await settle();assert int(d.ready_o.value);await edge(d)
    d.rsv_i.value=0;await settle();assert not int(d.ready_o.value)
    d.enq_i.value=1;d.enq_pair_i.value=1;d.data_i.value=111;d.data2_i.value=222;d.mask2_i.value=1
    await settle();assert int(d.wake_valid_o.value) and int(d.wake_preg_o.value)==33
    await edge(d);d.enq_i.value=0;d.enq_pair_i.value=0
    for _ in range(4):
        await settle();assert int(d.head_valid_o.value) and int(d.data_o.value)==111
        assert int(d.bypass_valid_o.value) and not int(d.wake_valid_o.value)
        await edge(d)
    d.consume_i.value=1;await settle();assert int(d.wake_valid_o.value) and int(d.wake_preg_o.value)==34
    await edge(d);d.consume_i.value=0;await settle();assert int(d.data_o.value)==222
    d.kill_i.value=1;await settle();assert not int(d.head_valid_o.value);await edge(d);d.kill_i.value=0
    await settle();assert not int(d.busy_o.value) and int(d.ready_o.value)
    # C clears branch dependencies; reusing its tag cannot remove this queued result.
    d.rsv_i.value=1;d.pair_i.value=0;await edge(d);d.rsv_i.value=0
    d.enq_i.value=1;d.mask_i.value=1;await edge(d);d.enq_i.value=0
    d.correct_i.value=1;await edge(d);d.correct_i.value=0;d.kill_i.value=1;await settle();assert int(d.head_valid_o.value)
    await edge(d);d.kill_i.value=0;d.consume_i.value=1;await edge(d);d.consume_i.value=0
    # Cancel before enqueue returns reserved pipeline credit without creating a result.
    d.rsv_i.value=1;await edge(d);d.rsv_i.value=0;d.release_i.value=1;await edge(d);d.release_i.value=0
    await settle();assert not int(d.busy_o.value)
    d.rst.value=1;await edge(d);d.rst.value=0;await settle();assert not int(d.head_valid_o.value)


@cocotb.test()
async def stationary_payload_credit_conservation(d):
    """Observe results/credits through ports across fragmentation and cancellation."""
    import random
    rng = random.Random(105)
    for n in ['clk','rsv_i','pair_i','enq_i','enq_pair_i','consume_i','kill_i','correct_i','release_i','data_i','data2_i','mask_i','mask2_i']:
        getattr(d,n).value=0
    d.rst.value=1
    await edge(d)
    d.rst.value=0
    depth=int(d.depth_o.value)
    queue=[]
    pipeline=0
    serial=0
    for cycle in range(900):
        reset=cycle % 173 == 172
        killed=rng.randrange(9)==0
        corrected=not killed and rng.randrange(7)==0
        head_valid=bool(queue) and not (killed and queue[0][2]&1)
        consume=head_valid and rng.randrange(4)!=0
        released=rng.randrange(min(2,pipeline)+1)
        enqueues=rng.randrange(min(2,pipeline-released)+1)
        pair=rng.randrange(3)==0
        reserve=rng.randrange(4)!=0
        used=len(queue)+pipeline
        ready=used+(2 if pair else 1)<=depth
        appended=[]
        for n in range(2):
            serial+=1
            appended.append((serial*101+n,33+n,rng.randrange(4)))
        d.rst.value=reset
        for name,value in [('rsv_i',reserve),('pair_i',pair),('enq_i',enqueues>0),('enq_pair_i',enqueues==2),('consume_i',consume),('kill_i',killed),('correct_i',corrected),('release_i',released),('data_i',appended[0][0]),('data2_i',appended[1][0]),('mask_i',appended[0][2]),('mask2_i',appended[1][2])]:
            getattr(d,name).value=value
        await settle()
        assert bool(int(d.ready_o.value)) == (ready and not reset), cycle
        assert bool(int(d.head_valid_o.value)) == (head_valid and not reset), cycle
        assert bool(int(d.bypass_valid_o.value)) == (head_valid and not reset), cycle
        assert bool(int(d.busy_o.value)) == bool(used), cycle
        if head_valid and not reset:
            assert int(d.data_o.value)==queue[0][0], (cycle,queue)
            assert int(d.bypass_data_o.value)==queue[0][0], cycle
            assert int(d.preg_o.value)==queue[0][1], cycle
        next_queue=[]
        returns=released
        for pos,item in enumerate(queue):
            if (killed and item[2]&1) or (pos==0 and consume):
                returns+=1
            else:
                next_queue.append((item[0],item[1],item[2]&~1 if killed or corrected else item[2]))
        for item in appended[:enqueues]:
            if killed and item[2]&1:
                returns+=1
            else:
                next_queue.append((item[0],item[1],item[2]&~1 if killed or corrected else item[2]))
        expected_wake=bool(next_queue) and (not head_valid or consume) and not reset
        assert bool(int(d.wake_valid_o.value))==expected_wake, (cycle,queue,next_queue)
        if expected_wake:
            assert int(d.wake_preg_o.value)==next_queue[0][1], cycle
        await edge(d)
        if reset:
            queue=[];pipeline=0
        else:
            pipeline=pipeline-released-enqueues+(2 if pair else 1)*int(reserve and ready)
            queue=next_queue
            assert 0<=len(queue)+pipeline<=depth, cycle
            assert len(queue)+pipeline==used-returns+(2 if pair else 1)*int(reserve and ready), cycle
