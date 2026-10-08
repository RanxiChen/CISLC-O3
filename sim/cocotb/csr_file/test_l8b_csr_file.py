import cocotb
from test_csr_file import edge,settle

@cocotb.test()
async def misa_a_present_and_warl(d):
    for n in ['mtime_i','irq_i','sret_i','interrupt_i','fp_valid_i','fp_dirty_i','fp_flags_i','clk','req_valid_i','write_i','op_i','addr_i','data_i','retired_i','fe_perf_i','be_perf_i','trap_i','xret_i','cause_i','epc_i','tval_i']:
        getattr(d,n).value=0
    d.rst.value=1;await edge(d);d.rst.value=0
    d.req_valid_i.value=1;d.addr_i.value=0x301;d.op_i.value=2;await settle()
    assert not int(d.illegal_o.value) and int(d.read_o.value)&1
    original=int(d.read_o.value);d.op_i.value=1;d.write_i.value=1;d.data_i.value=0
    await edge(d);d.write_i.value=0;d.op_i.value=2;await settle()
    assert int(d.read_o.value)==original and int(d.read_o.value)&1
