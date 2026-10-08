import cocotb
from cocotb.triggers import Timer

@cocotb.test()
async def all_atomic_encodings_and_reserved(d):
    # enum values follow the public amo_op_e interface; oracle is ISA funct5.
    ops={2:0,3:1,1:2,0:3,4:4,12:5,8:6,16:7,20:8,24:9,28:10}
    for f5 in range(32):
        for f3 in range(8):
            for aqrl in range(4):
                for rs2 in (0,31): # LR reserved rs2 is ignored per spec 3.
                    for rd in (0,7):
                        insn=(f5<<27)|(aqrl<<25)|(rs2<<20)|(5<<15)|(f3<<12)|(rd<<7)|0x2f
                        d.instruction_i.value=insn;await Timer(1,unit='ns')
                        legal=f5 in ops and f3 in (2,3)
                        assert bool(int(d.illegal_o.value)) == (not legal),hex(insn)
                        if legal:
                            assert int(d.amo_op_o.value)==ops[f5],hex(insn)
                            assert int(d.aq_o.value)==aqrl>>1 and int(d.rl_o.value)==aqrl&1
                            assert int(d.size_o.value)==f3
                            assert int(d.store_o.value)==1 and int(d.load_o.value)==0
                            assert int(d.rs1_read_o.value)==1
                            assert int(d.rs2_read_o.value)==(f5!=2)
