"""L1 sequential prediction contract, independent of BPU RTL state layout."""
from dataclasses import dataclass


@dataclass(frozen=True)
class Inputs:
    rst: bool = False
    boot_pc: int = 0x10000000
    ready: bool = False
    ftq_id: int = 0
    hold: bool = False
    recover: bool = False
    kill: bool = False
    train: bool = False


class BpuModel:
    def __init__(self, region_bytes: int, vaddr_bits: int):
        self.region_bytes = region_bytes
        self.mask = (1 << vaddr_bits) - 1
        self.pc = 0
        self.completion = None

    def visible(self, i: Inputs):
        base = self.pc & ~(self.region_bytes - 1)
        next_pc = (base + self.region_bytes) & self.mask
        valid = not (i.rst or i.hold or i.recover or i.kill)
        return {
            "valid": valid,
            "base": base,
            "slot": (self.pc - base) // 2,
            "next": next_pc,
            "completion": self.completion,
        }

    def tick(self, i: Inputs):
        if i.rst:
            self.pc = i.boot_pc
            self.completion = None
            return
        visible = self.visible(i)
        self.completion = None
        if visible["valid"] and i.ready:
            self.completion = (i.ftq_id, visible["base"], visible["next"])
            self.pc = visible["next"]
