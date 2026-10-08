import cocotb
from cocotb.triggers import Timer


async def step(d):
    d.clk.value = 0
    await Timer(5, unit='ns')
    d.clk.value = 1
    await Timer(5, unit='ns')


async def reset(d):
    for n in ('clk', 'req_valid_i', 'write_i', 'paddr_i', 'data_i', 'mask_i',
              'resp_ready_i', 'coh_req_ready_i', 'coh_resp_valid_i', 'coh_resp_i'):
        getattr(d, n).value = 0
    d.rst.value = 1
    await step(d)
    d.rst.value = 0
    await step(d)


@cocotb.test()
async def read_write_fields_single_credit_and_retained_response(d):
    await reset(d)
    for write in (0, 1):
        d.write_i.value = write
        d.paddr_i.value = 0x80123440
        data = int.from_bytes(bytes(range(64)), 'little')
        mask = 0x80000001000000a5
        d.data_i.value = data; d.mask_i.value = mask; d.req_valid_i.value = 1
        assert int(d.req_ready_o.value)
        await step(d)
        d.req_valid_i.value = 0
        for _ in range(12):
            await Timer(1, unit='ns')
            assert int(d.coh_req_valid_o.value)
            assert (int(d.op_o.value), int(d.line_o.value), int(d.id_o.value)) == (3 if write else 2, 0x80123440 >> 6, 0)
            assert int(d.data_o.value) == data and int(d.mask_o.value) == mask
            assert not int(d.req_ready_o.value)
            # A second presented request must not overwrite the retained one.
            d.req_valid_i.value = 1; d.paddr_i.value = 0x80200000
            await step(d)
        d.req_valid_i.value = 0; d.coh_req_ready_i.value = 1
        await step(d)
        d.coh_req_ready_i.value = 0
        assert not int(d.coh_req_valid_o.value) and int(d.coh_resp_ready_o.value)
        for _ in range(12):
            assert not int(d.req_ready_o.value)
            await step(d)
        returned = data ^ ((1 << 512) - 1)
        d.coh_resp_i.value = ((5 if write else 4) << 515) | returned
        d.coh_resp_valid_i.value = 1
        await step(d)
        d.coh_resp_valid_i.value = 0
        for _ in range(12):
            assert int(d.resp_valid_o.value) and not int(d.error_o.value)
            assert int(d.rdata_o.value) == returned and not int(d.req_ready_o.value)
            await step(d)
        d.resp_ready_i.value = 1
        await step(d)
        d.resp_ready_i.value = 0
        assert int(d.req_ready_o.value) and not int(d.resp_valid_o.value)


@cocotb.test()
async def invalid_physical_addresses_and_error_propagation(d):
    await reset(d)
    for addr in (0, 0x2000000, 0x7fffffc0, 0x100000000, 0x180000000, (1 << 56) - 64):
        d.paddr_i.value = addr; d.req_valid_i.value = 1
        await step(d)
        d.req_valid_i.value = 0
        assert int(d.resp_valid_o.value) and int(d.error_o.value)
        for _ in range(8):
            assert not int(d.coh_req_valid_o.value) and not int(d.req_ready_o.value)
            await step(d)
        d.resp_ready_i.value = 1
        await step(d)
        d.resp_ready_i.value = 0
    for write in (0, 1):
        d.write_i.value = write; d.paddr_i.value = 0xffffffc0; d.req_valid_i.value = 1
        await step(d)
        d.req_valid_i.value = 0; d.coh_req_ready_i.value = 1
        await step(d)
        d.coh_req_ready_i.value = 0
        d.coh_resp_i.value = ((5 if write else 4) << 515) | (1 << 512)
        d.coh_resp_valid_i.value = 1
        await step(d)
        d.coh_resp_valid_i.value = 0
        assert int(d.resp_valid_o.value) and int(d.error_o.value)
        d.resp_ready_i.value = 1
        await step(d)
        d.resp_ready_i.value = 0
