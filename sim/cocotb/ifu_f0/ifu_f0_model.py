"""Specification oracle for compacted RV64I regression within the L7b F0.

RVC/edge state is covered by explicit directed public-port tests rather than
this straight-line oracle. Position is independent from the output lane.
"""
def rv64i_slots(entry, region_slots=8, fault=False):
    return [entry] if fault else list(range(entry,region_slots,2))
