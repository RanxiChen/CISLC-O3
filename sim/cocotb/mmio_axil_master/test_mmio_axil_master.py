import cocotb
from cocotb.triggers import Timer

MASK64 = (1 << 64) - 1


async def settle():
    await Timer(1, unit='ns')


async def step(d):
    d.clk.value = 0
    await Timer(5, unit='ns')
    d.clk.value = 1
    await Timer(5, unit='ns')


async def reset(d):
    for n in ('clk', 'req_valid_i', 'write_i', 'paddr_i', 'vaddr_i', 'size_i', 'signed_i', 'flw_i',
              'data_i', 'mask_i', 'resp_ready_i', 'm_axil_awready', 'm_axil_wready',
              'm_axil_bvalid', 'm_axil_bresp', 'm_axil_arready', 'm_axil_rvalid',
              'm_axil_rdata', 'm_axil_rresp'):
        getattr(d, n).value = 0
    d.rst.value = 1
    await step(d)
    d.rst.value = 0
    await step(d)


async def transaction(d, write, size, offset, signed=False, flw=False, error=0, delays=(0, 5)):
    addr = 0x02001000 + offset
    va = 0xffffffff02001000 + offset
    raw_bytes = bytes((0x81 + 13 * i) & 255 for i in range(8))
    raw = int.from_bytes(raw_bytes, 'little')
    value = 0xfedcba9876543210
    count = 1 << size
    mask = (1 << count) - 1
    d.write_i.value = write; d.paddr_i.value = addr; d.vaddr_i.value = va
    d.size_i.value = size; d.signed_i.value = signed; d.flw_i.value = flw
    d.data_i.value = value; d.mask_i.value = mask; d.req_valid_i.value = 1
    await settle()
    assert int(d.req_ready_o.value)
    await step(d)
    d.req_valid_i.value = 0
    aw = w = ar = 0
    for cycle in range(40):
        d.m_axil_awready.value = cycle >= delays[0]
        d.m_axil_wready.value = cycle >= delays[1]
        d.m_axil_arready.value = cycle >= max(delays)
        await settle()
        assert not int(d.req_ready_o.value) and int(d.irreversible_o.value)
        if int(d.m_axil_awvalid.value):
            assert write and not aw
            assert int(d.m_axil_awaddr.value) == addr and int(d.m_axil_awprot.value) == 0
            aw += int(d.m_axil_awready.value)
        if int(d.m_axil_wvalid.value):
            assert write and not w
            expected = bytearray(8)
            expected[offset:offset + count] = value.to_bytes(8, 'little')[:count]
            # Unselected lanes need not be zero; selected bytes must match the independent byte oracle.
            observed = int(d.m_axil_wdata.value).to_bytes(8, 'little')
            assert observed[offset:offset + count] == expected[offset:offset + count]
            assert int(d.m_axil_wstrb.value) == sum(1 << i for i in range(offset, offset + count))
            w += int(d.m_axil_wready.value)
        if int(d.m_axil_arvalid.value):
            assert not write and not ar
            assert int(d.m_axil_araddr.value) == addr and int(d.m_axil_arprot.value) == 0
            ar += int(d.m_axil_arready.value)
        await step(d)
        if (aw and w) if write else ar:
            break
    else:
        assert False, 'AXI issue watchdog'
    d.m_axil_awready.value = 0; d.m_axil_wready.value = 0; d.m_axil_arready.value = 0
    for _ in range(8):
        assert not int(d.m_axil_awvalid.value) and not int(d.m_axil_wvalid.value) and not int(d.m_axil_arvalid.value)
        assert int(d.m_axil_bready.value) == write and int(d.m_axil_rready.value) == (not write)
        await step(d)
    d.m_axil_bvalid.value = write; d.m_axil_bresp.value = error
    d.m_axil_rvalid.value = not write; d.m_axil_rresp.value = error; d.m_axil_rdata.value = raw
    await step(d)
    d.m_axil_bvalid.value = 0; d.m_axil_rvalid.value = 0
    payload = int.from_bytes(raw_bytes[offset:offset + count], 'little', signed=signed) & MASK64
    if flw:
        payload = 0xffffffff00000000 | (payload & 0xffffffff)
    snapshot = None
    for _ in range(12):
        assert int(d.resp_valid_o.value) and not int(d.req_ready_o.value)
        assert int(d.error_o.value) == bool(error)
        if error:
            exc = int(d.exc_o.value)
            assert exc >> 70 == 1 and (exc >> 64) & 63 == (7 if write else 5)
            assert exc & MASK64 == va
        elif not write:
            assert int(d.rdata_o.value) == payload, (size, offset, signed, flw)
        now = (int(d.rdata_o.value), int(d.error_o.value), int(d.exc_o.value))
        assert snapshot is None or now == snapshot, 'response changed while backpressured'
        snapshot = now
        await step(d)
    d.resp_ready_i.value = 1
    await step(d)
    d.resp_ready_i.value = 0
    assert int(d.req_ready_o.value) and not int(d.resp_valid_o.value) and not int(d.irreversible_o.value)


@cocotb.test()
async def loads_all_lane_offsets_sign_extension_and_nan_boxing(d):
    await reset(d)
    for size in range(4):
        for offset in range(0, 8, 1 << size):
            for signed in (False, True):
                await transaction(d, 0, size, offset, signed=signed)
    for offset in (0, 4):
        await transaction(d, 0, 2, offset, flw=True)


@cocotb.test()
async def stores_byte_enables_and_independent_aw_w_backpressure(d):
    await reset(d)
    for size in range(4):
        for offset in range(0, 8, 1 << size):
            for delays in ((0, 5), (5, 0), (3, 3), (11, 7)):
                await transaction(d, 1, size, offset, delays=delays)


@cocotb.test()
async def all_non_okay_responses_report_precise_virtual_address(d):
    await reset(d)
    for write in (0, 1):
        for response in (1, 2, 3):
            await transaction(d, write, 2, 4, error=response)
