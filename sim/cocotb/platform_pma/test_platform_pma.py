"""Independent expectations from L11a section 3.2 and the CSR revision.

Do not load the generator or JSON into this oracle: an accidental platform
change must fail until its specification and expectations are reviewed.
"""
import cocotb
from cocotb.triggers import Timer

# lo, exclusive hi, (exists, R, W, X, cacheable, device, AMO, reservation)
REGIONS = (
    (0x02000000, 0x02010000, (1, 1, 1, 0, 0, 1, 0, 0)),
    (0x0C000000, 0x10000000, (1, 1, 1, 0, 0, 1, 0, 0)),
    (0x10000000, 0x10010000, (1, 1, 0, 1, 1, 0, 0, 0)),
    (0x10010000, 0x10020000, (1, 1, 0, 1, 1, 0, 0, 0)),
    (0x11000000, 0x11010000, (1, 1, 1, 1, 1, 0, 1, 1)),
    (0x12000000, 0x12100000, (1, 1, 1, 0, 0, 1, 0, 0)),
    (0x80000000, 0x100000000, (1, 1, 1, 1, 1, 0, 1, 1)),
)
OUTPUTS = ("exists_o", "read_ok_o", "write_ok_o", "exec_ok_o",
           "cacheable_o", "io_o", "amo_ok_o", "rsrv_ok_o")


@cocotb.test()
async def exact_platform_attributes_boundaries_and_holes(dut):
    probes = set()
    for lo, hi, _ in REGIONS:
        for size in (0, 1, 2, 4, 8, 16, 64, 127):
            for addr in (lo - 1, lo, lo + 1, hi - size, hi - 1, hi, hi + 1):
                probes.add((addr, size))
    # Former ERR hole is now covered by the expanded CSR bridge. Addresses
    # beyond 1MiB, including the old 16MiB tail, are absent.
    probes.update((addr, size) for addr in (
        0, 0x03000000, 0x10030000, 0x11020000, 0x12010000,
        0x120FF000, 0x120FFFF8, 0x12100000, 0x12FFFFFF,
        0x13000000, 0x7FFFFFFF, 0xFFFFF000, 0x180000000,
        0xFFFFFFFFFFFFFFF8) for size in (1, 4, 8, 16, 64))
    for addr, size in sorted(probes):
        expected = next((attrs for lo, hi, attrs in REGIONS
                         if size > 0 and lo <= addr and addr + size <= hi), (0,) * 8)
        dut.paddr_i.value = addr
        dut.bytes_i.value = size
        await Timer(1, unit="ns")
        actual = tuple(int(getattr(dut, name).value) for name in OUTPUTS)
        assert actual == expected, (hex(addr), size, actual, expected)
