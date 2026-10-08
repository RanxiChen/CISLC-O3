"""IRQ raised by an irreversible MMIO write must follow its retirement."""
import cocotb
from cocotb.triggers import Timer


def imm(rd,rs1,value):
    return ((value&4095)<<20)|(rs1<<15)|(rd<<7)|0x13


def store(rs2,rs1):
    return (rs2<<20)|(rs1<<15)|(3<<12)|0x23


@cocotb.test()
async def mmio_irq_trigger_retires_once_before_interrupt(d):
    base=0x80000000
    # mtvec=base+0x80; MSI enable; MMIO[830]=1; then two side-effect reads.
    code=[0x297,imm(5,5,0x80),0x30529073,imm(20,0,0),imm(5,0,8),
          0x30429073,0x3002a073,(0x02001<<12)|(6<<7)|0x37,
          imm(6,6,-0x7d0),imm(5,0,1),store(5,6),imm(6,6,-0x30),
          (6<<15)|(3<<12)|(10<<7)|3,(6<<15)|(3<<12)|(11<<7)|3,0x6f]
    code += [0x13]*(32-len(code))
    # Handler uses t3, preserving the interrupted program's t1.
    code += [(0x02001<<12)|(28<<7)|0x37,imm(28,28,-0x7c8),
             store(0,28),imm(20,20,1),0x30200073]
    rows=[]
    async def tick():
        d.clk_i.value=0;await Timer(5,unit='ns')
        for lane in range(len(d.tandem_pc_o)):
            if (int(d.tandem_valid_o.value)>>lane)&1:
                rows.append(dict(pc=int(d.tandem_pc_o[lane].value),
                    trap=(int(d.tandem_exc_valid_o.value)>>lane)&1,
                    rd=int(d.tandem_rd_o[lane].value),
                    write=(int(d.tandem_rd_write_o.value)>>lane)&1,
                    data=int(d.tandem_rd_wdata_o[lane].value),
                    kind=int(d.tandem_mem_kind_o[lane].value),
                    addr=int(d.tandem_mem_addr_o[lane].value)))
        assert not int(d.fatal_o.value) and not int(d.inclusion_err_o.value)
        d.clk_i.value=1;await Timer(5,unit='ns')
    d.clk_i.value=0;d.rst_i.value=1;d.reset_pc_i.value=base
    d.axi_init_valid_i.value=1;d.axi_init_wmask_i.value=0xffff
    for pos in range(0,len(code),4):
        d.axi_init_addr_i.value=base+4*pos
        d.axi_init_data_i.value=sum(w<<(32*n) for n,w in enumerate(code[pos:pos+4]))
        await tick()
    d.axi_init_valid_i.value=0;d.rst_i.value=0;rows.clear()
    for _ in range(int(d.cfg_l2_sets_o.value)+1):
        if int(d.cache_init_done_o.value):break
        await tick();assert not rows
    assert int(d.cache_init_done_o.value),'cache initialization watchdog'
    for _ in range(2000):
        await tick()
        if any(r['write'] and r['rd']==11 for r in rows):break
    values={r['rd']:r['data'] for r in rows if r['write']}
    assert values.get(20)==1 and values.get(10)==0 and values.get(11)==1,values
    trigger=[r for r in rows if r['kind']==2 and r['addr']==0x02000830]
    clears=[r for r in rows if r['kind']==2 and r['addr']==0x02000838]
    traps=[r for r in rows if r['trap']]
    assert len(trigger)==len(clears)==len(traps)==1,(trigger,clears,traps)
    assert rows.index(trigger[0])<rows.index(traps[0]),'external write interrupted before retirement'
    assert int(d.mmio_side_reads_o.value)==2,'MMIO loads executed more than once'
