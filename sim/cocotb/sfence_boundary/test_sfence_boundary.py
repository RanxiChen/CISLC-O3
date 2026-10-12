import os,random
import cocotb
from cocotb.triggers import Timer

@cocotb.test()
async def registered_range_and_flush_with_continuous_commands(d):
    seed=int(os.getenv('TEST_SEED','1'));rng=random.Random(seed)
    d.clk.value=0;d.rst.value=1;d.flush_i.value=0;d.request_valid_i.value=0;d.request_payload_i.value=0
    await Timer(1,unit='ns');d.clk.value=1;await Timer(1,unit='ns');d.clk.value=0
    stored=(0,0)
    for cycle in range(500):
        reset=cycle in [0,151,397];flush=cycle in [3,4] or rng.randrange(13)==0
        valid=cycle<32 or rng.randrange(3)!=0
        payload=rng.getrandbits(len(d.request_payload_i))
        d.rst.value=int(reset);d.flush_i.value=int(flush)
        d.request_valid_i.value=int(valid);d.request_payload_i.value=payload
        await Timer(1,unit='ns')
        assert (int(d.command_valid_o.value),int(d.command_payload_o.value))==stored,(seed,cycle,'before command edge')
        d.clk.value=1;await Timer(1,unit='ns')
        stored=(0,0) if reset or flush else (int(valid),payload)
        assert (int(d.command_valid_o.value),int(d.command_payload_o.value))==stored,(seed,cycle,'command ownership')
        d.clk.value=0
