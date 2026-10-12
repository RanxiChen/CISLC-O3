import os,random
import cocotb
from cocotb.triggers import Timer

@cocotb.test()
async def frozen_redirect_and_registered_cancel_for_every_packet(d):
    rng=random.Random(int(os.getenv('TEST_SEED','1')))
    for name in ['clk','cancel_i','redirect_valid_i','redirect_payload_i',
                 'trap_valid_i','trap_done_i','trap_epc_i','trap_target_i','trap_cause_i']:
        getattr(d,name).value=0
    d.rst.value=1;await Timer(1,unit='ns');d.clk.value=1;await Timer(1,unit='ns');d.clk.value=0
    stored_cancel=0;stored_refetch=(0,0)
    for cycle in range(500):
        reset=cycle in [0,1,123,301]
        cancel=int(cycle in [2,3,4] or rng.randrange(8)==0)
        valid=int(cycle in [2,3,4] or rng.randrange(5)==0)
        # Retain the random stream and old 500-cycle scale. A trap target now
        # uses the same dispatch stage instead of bypassing its packet register.
        _trap=int(cycle==5 or rng.randrange(9)==0)
        payload=rng.getrandbits(len(d.redirect_payload_i))
        d.clk.value=0;d.rst.value=int(reset);d.cancel_i.value=cancel
        d.redirect_valid_i.value=valid;d.redirect_payload_i.value=payload
        await Timer(1,unit='ns')
        want=stored_refetch
        assert int(d.cancel_o.value)==stored_cancel,(cycle,'cancel')
        assert int(d.pending_o.value)==int(stored_cancel or stored_refetch[0]),(cycle,'pending')
        assert int(d.redirect_valid_o.value)==want[0],(cycle,'redirect valid')
        if want[0]:assert int(d.redirect_payload_o.value)==want[1],(cycle,'frozen payload')
        d.clk.value=1;await Timer(1,unit='ns')
        stored_cancel=0 if reset else cancel
        stored_refetch=(0,0) if reset else (valid,payload)
        d.clk.value=0

@cocotb.test()
async def precise_trap_cancel_update_target_and_dispatch_hold(d):
    rng=random.Random(int(os.getenv('TEST_SEED','1'))+105)
    for name in ['clk','cancel_i','redirect_valid_i','redirect_payload_i',
                 'trap_valid_i','trap_done_i','trap_epc_i','trap_target_i','trap_cause_i']:
        getattr(d,name).value=0
    async def edge():
        d.clk.value=0;await Timer(1,unit='ns')
        d.clk.value=1;await Timer(1,unit='ns');d.clk.value=0
    d.rst.value=1;await edge();d.rst.value=0
    for event in range(160):
        epc=rng.getrandbits(64);target=rng.getrandbits(64);cause=rng.randrange(64)
        d.trap_valid_i.value=1;d.trap_epc_i.value=epc;d.trap_cause_i.value=cause
        d.trap_target_i.value=rng.getrandbits(64);d.trap_done_i.value=1
        await Timer(1,unit='ns')
        assert not int(d.transport_redirect_o.value),(event,'no C0 target')
        await edge() # C1: precise cancellation and the frozen CSR request.
        assert int(d.transport_busy_o.value) and int(d.transport_cancel_o.value)
        assert int(d.trap_update_o.value)
        assert int(d.trap_update_epc_o.value)==epc
        assert int(d.trap_update_cause_o.value)==cause
        d.trap_valid_i.value=0;d.trap_epc_i.value=rng.getrandbits(64)
        d.trap_target_i.value=target
        await edge() # C2: target capture; frontend dispatch still awaits its edge.
        assert int(d.transport_busy_o.value) and not int(d.transport_cancel_o.value)
        assert not int(d.trap_update_o.value) and not int(d.transport_redirect_o.value)
        d.trap_target_i.value=rng.getrandbits(64)
        await edge() # C3: the complete frozen target packet owns the boundary.
        assert int(d.transport_busy_o.value) and int(d.transport_redirect_o.value)
        assert int(d.transport_pc_o.value)==target,(event,'target identity')
        await edge()
        assert not int(d.transport_busy_o.value) and not int(d.transport_redirect_o.value)
        if event%19==0:
            d.trap_valid_i.value=1;await edge()
            d.rst.value=1;d.trap_valid_i.value=0;await edge();d.rst.value=0
            assert not int(d.transport_busy_o.value) and not int(d.transport_cancel_o.value)
