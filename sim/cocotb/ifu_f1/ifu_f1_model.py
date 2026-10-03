"""L1 F0-to-fetch-entry packing contract."""
from dataclasses import dataclass


@dataclass(frozen=True)
class Inputs:
    rst: bool = False
    valid_mask: int = 0
    pcs: tuple[int, ...] = (0,) * 8
    instructions: tuple[int, ...] = (0,) * 8
    ids: tuple[int, ...] = (0,) * 8
    ready: bool = False
    kill: bool = False
    cfi_valid: bool = False
    cfi_slot: int = 0
    raw_taken: bool = False
    next_pc: int = 0


def visible(i: Inputs, width: int):
    ready = i.ready and not (i.rst or i.kill)
    if i.rst or i.kill:
        return ready, []
    slots = [slot for slot in range(len(i.pcs)) if i.valid_mask & (1 << slot)]
    output = []
    for slot in slots[:width]:
        taken = i.cfi_valid and i.raw_taken and slot == i.cfi_slot
        output.append({
            "pc": i.pcs[slot], "instruction": i.instructions[slot],
            "ftq_id": i.ids[slot], "slot": slot,
            "last": False, "taken": taken,
            "next_pc": i.next_pc if taken else i.pcs[slot] + 4,
        })
    if output:
        output[-1]["last"] = True
    return ready, output
