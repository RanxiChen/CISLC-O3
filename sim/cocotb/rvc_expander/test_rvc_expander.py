"""Vectors translated from Flow AirRvcDecompressorSpec at 02e3f6fd.
Additional hard-coded ISA encodings cover immediate boundaries and quadrants.
"""
import cocotb
from cocotb.triggers import Timer

@cocotb.test()
async def flow_vectors(d):
    for raw,legal,expanded in [(0x0001,1,0x00000013),(0x9002,1,0x00100073),
                              (0x918a,1,0x002181b3),(0x4095,1,0x00500093),(0,0,0)]:
        d.in_i.value=raw
        await Timer(1,unit='ns')
        assert int(d.legal_o.value)==legal,hex(raw)
        assert int(d.out_o.value)==expanded,hex(raw)

@cocotb.test()
async def reserved_and_integer_boundaries(d):
    for raw,expanded in [(0x0085,0x00108093),(0x10fd,0xfff08093),
                         (0x8082,0x00008067),(0x9082,0x000080e7),
                         (0x0086,0x00109093),(0xa001,0x0000006f),
                         (0xc001,0x00040063),(0xe001,0x00041063),
                         (0x4000,0x00042403),(0x6000,0x00043403),
                         (0xc000,0x00842023),(0xe000,0x00843023)]:
        d.in_i.value=raw;await Timer(1,unit='ns')
        assert int(d.legal_o.value)==1,hex(raw)
        assert int(d.out_o.value)==expanded,(hex(raw),hex(int(d.out_o.value)))
    for raw in [0x8002,0x0002,0x2001,0x9c41,0xffff,0x6181]:
        d.in_i.value=raw;await Timer(1,unit='ns')
        assert int(d.legal_o.value)==0,hex(raw)

@cocotb.test()
async def fp_load_store_vectors(d):
    # RV64C: FLD/FSD f8,0(x8); FLDSP/FSDSP f0,0(sp). f0 is writable.
    for raw,expanded in [(0x2000,0x00043407),(0xa000,0x00843027),
                         (0x2002,0x00013007),(0xa002,0x00013027)]:
        d.in_i.value=raw;await Timer(1,unit='ns')
        assert int(d.legal_o.value)==1,hex(raw)
        assert int(d.out_o.value)==expanded,(hex(raw),hex(int(d.out_o.value)))
