"""Real WB bridge + real line adapter; an independent L2 response endpoint."""
import cocotb
from cocotb.triggers import Timer


async def settle():
    await Timer(1, unit="ns")


async def step(d):
    d.clk_i.value = 0
    await Timer(5, unit="ns")
    d.clk_i.value = 1
    await Timer(5, unit="ns")


async def reset(d):
    for n in ("clk_i", "wb_adr_i", "wb_dat_w_i", "wb_sel_i", "wb_cyc_i",
              "wb_stb_i", "wb_we_i", "coh_req_ready_i", "coh_resp_valid_i",
              "coh_resp_data_i", "coh_resp_error_i", "coh_resp_op_i"):
        getattr(d, n).value = 0
    d.rst_i.value = 1
    await step(d)
    d.rst_i.value = 0
    await step(d)


async def begin(d, addr, write=0, sel=255, data=0):
    d.wb_adr_i.value = addr // 8
    d.wb_we_i.value = write
    d.wb_sel_i.value = sel
    d.wb_dat_w_i.value = data
    d.wb_cyc_i.value = d.wb_stb_i.value = 1
    await step(d)


async def wait_coh(d):
    for _ in range(10):
        await settle()
        assert not int(d.wb_ack_o.value) and not int(d.wb_err_o.value)
        if int(d.coh_req_valid_o.value):
            return
        await step(d)
    assert False, "coherent request missing"


async def respond(d, write, data=0, error=0):
    d.coh_req_ready_i.value = 1
    await step(d)
    d.coh_req_ready_i.value = 0
    assert int(d.coh_resp_ready_o.value)
    d.coh_resp_op_i.value = 5 if write else 4
    d.coh_resp_data_i.value = data
    d.coh_resp_error_i.value = error
    d.coh_resp_valid_i.value = 1
    await step(d)
    d.coh_resp_valid_i.value = 0
    await step(d)
    await settle()


async def finish(d):
    d.wb_cyc_i.value = d.wb_stb_i.value = 0
    await step(d)
    assert not int(d.busy_o.value)
    assert int(d.dma_req_ready_o.value)


@cocotb.test()
async def all_word_slots_and_all_byte_masks(d):
    await reset(d)
    payload = bytes(range(8))
    returned = bytes((i * 13 + 7) & 255 for i in range(64))
    transactions = 0
    for slot in range(8):
        addr = 0xffffffc0 + slot * 8
        await begin(d, addr)
        await wait_coh(d)
        assert (int(d.coh_op_o.value), int(d.coh_line_o.value)) == (2, 0xffffffc0 // 64)
        await respond(d, 0, int.from_bytes(returned, "little"))
        assert int(d.wb_ack_o.value) and not int(d.wb_err_o.value)
        assert int(d.wb_dat_r_o.value) == int.from_bytes(returned[slot*8:slot*8+8], "little")
        await finish(d)
        transactions += 1
        for sel in range(256):
            await begin(d, addr, 1, sel, int.from_bytes(payload, "little"))
            if sel == 0:
                assert not int(d.dma_req_valid_o.value)
                assert int(d.wb_ack_o.value) and not int(d.wb_err_o.value)
            else:
                await wait_coh(d)
                expected = bytearray(64)
                expected[slot*8:slot*8+8] = payload
                expected_mask = sum(1 << i for i in range(64)
                    if slot*8 <= i < slot*8+8 and sel & (1 << (i-slot*8)))
                assert (int(d.coh_op_o.value), int(d.coh_line_o.value)) == (3, addr // 64)
                assert int(d.coh_data_o.value) == int.from_bytes(expected, "little")
                assert int(d.coh_mask_o.value) == expected_mask
                await respond(d, 1)
                assert int(d.wb_ack_o.value) and not int(d.wb_err_o.value)
            await finish(d)
            transactions += 1
    d._log.info("Checked %d WB transactions (all 8 slots x 256 write masks plus reads)", transactions)


@cocotb.test()
async def retained_request_backpressure_response_and_errors(d):
    await reset(d)
    for write in (0, 1):
        for error in (0, 1):
            await begin(d, 0x80001238, write, 0xa5, 0xabcdef1234567890)
            await wait_coh(d)
            fields = tuple(int(getattr(d, n).value) for n in
                ("coh_op_o", "coh_line_o", "coh_data_o", "coh_mask_o"))
            for _ in range(16):
                assert tuple(int(getattr(d, n).value) for n in
                    ("coh_op_o", "coh_line_o", "coh_data_o", "coh_mask_o")) == fields
                assert int(d.coh_req_valid_o.value)
                assert not int(d.wb_ack_o.value) and not int(d.wb_err_o.value)
                await step(d)
            d.wb_stb_i.value = 0
            await respond(d, write, 0x1234 << (7*64), error)
            for _ in range(16):
                assert not int(d.wb_ack_o.value) and not int(d.wb_err_o.value)
                assert not int(d.coh_req_valid_o.value)
                await step(d)
            d.wb_stb_i.value = 1
            await settle()
            assert (int(d.wb_ack_o.value), int(d.wb_err_o.value)) == (1-error, error)
            assert int(d.wb_dat_r_o.value) == 0x1234
            await finish(d)
    for addr in (0, 0x02000000, 0x0c000000, 0x10000000, 0x10010000,
                 0x11000000, 0x12000000, 0x12100000, 0x7ffffff8):
        for write in (0, 1):
            await begin(d, addr, write)
            assert not int(d.dma_req_valid_o.value) and not int(d.coh_req_valid_o.value)
            assert int(d.wb_err_o.value) and not int(d.wb_ack_o.value)
            await finish(d)


@cocotb.test()
async def withdraw_before_line_accept_and_drain_after_accept(d):
    await reset(d)
    await begin(d, 0x80000000, 1)
    # Bridge has retained WB, but line adapter has not yet sampled valid.
    d.wb_cyc_i.value = 0
    await settle()
    assert not int(d.dma_req_valid_o.value)
    await step(d)
    assert not int(d.busy_o.value) and not int(d.coh_req_valid_o.value)
    for write in (0, 1):
        await begin(d, 0x80000020, write)
        await wait_coh(d)
        d.wb_cyc_i.value = 0
        for _ in range(8):
            await step(d)
            assert int(d.coh_req_valid_o.value)
            assert not int(d.wb_ack_o.value) and not int(d.wb_err_o.value)
        # A resumed bus cycle cannot receive the cancelled transaction's ACK.
        d.wb_cyc_i.value = 1
        await respond(d, write)
        assert not int(d.wb_ack_o.value) and not int(d.wb_err_o.value)
        await finish(d)


@cocotb.test()
async def reset_each_transaction_phase(d):
    for phase in ("send", "coherent_send", "wait", "response"):
        await reset(d)
        await begin(d, 0x80000000, 1)
        if phase != "send":
            await wait_coh(d)
        if phase == "wait":
            d.coh_req_ready_i.value = 1
            await step(d)
            d.coh_req_ready_i.value = 0
        if phase == "response":
            await respond(d, 1)
        d.wb_cyc_i.value = d.wb_stb_i.value = 0
        d.rst_i.value = 1
        await step(d)
        d.rst_i.value = 0
        await step(d)
        assert not int(d.busy_o.value) and not int(d.coh_req_valid_o.value)
        assert int(d.dma_req_ready_o.value)
        assert not int(d.wb_ack_o.value) and not int(d.wb_err_o.value)
