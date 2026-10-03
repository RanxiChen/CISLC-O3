"""Small reference helpers for the L2 direct-control recovery contract."""


def expected_redirect(branch_pc: int, inst_len: int, target: int, taken: bool) -> int:
    return target if taken else branch_pc + inst_len


def is_link_register(reg: int) -> bool:
    return reg in (1, 5)
