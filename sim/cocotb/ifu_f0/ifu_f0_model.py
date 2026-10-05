"""L5 RV64I instruction positions and precise frontend faults."""
from dataclasses import dataclass


@dataclass(frozen=True)
class Inputs:
    rst: bool = False
    valid: bool = False
    ready: bool = False
    base: int = 0x10000000
    data: int = 0
    ftq_id: int = 0
    entry_slot: int = 0
    cfi_valid: bool = False
    cfi_slot: int = 0
    kill: bool = False
    sync: bool = False
    exc: bool = False
    cause: int = 1


class F0Model:
    def __init__(self, region_bytes, slots):
        self.region_bytes = region_bytes
        self.slots = slots

    def visible(self, i: Inputs):
        active = i.valid and not (i.rst or i.kill or i.sync)
        ready = i.ready and not (i.rst or i.kill or i.sync)
        instructions = {}
        if active:
            for byte_offset in range(i.entry_slot * 2, self.region_bytes, 4):
                slot = byte_offset // 2
                if byte_offset + 4 > self.region_bytes:
                    break
                if i.cfi_valid and slot > i.cfi_slot:
                    break
                word = (i.data >> (8 * byte_offset)) & 0xffffffff
                if i.exc:
                    word = 0
                elif word & 3 != 3:
                    word &= 0xffff
                instructions[slot] = (i.base + byte_offset, word, 4, i.ftq_id)
        return ready, instructions
