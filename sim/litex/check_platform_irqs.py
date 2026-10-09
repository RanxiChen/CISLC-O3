#!/usr/bin/env python3
"""Real LiteX allocation/export and negative guards for the frozen PLIC IDs."""
import json
from o3_sim import make_soc


def main():
    soc = make_soc()
    soc.finalize()
    expected = {"uart": 10, "sdcard": 11, "timer0": 12}
    assert soc.irq.locs == expected
    actual = {name: getattr(soc.constants[name.upper()+"_INTERRUPT"], "value",
        soc.constants[name.upper()+"_INTERRUPT"]) for name in expected}
    assert actual == expected
    soc.check_memory_paths()
    soc.irq.locs["uart"] = 0
    try:
        soc.check_memory_paths()
    except ValueError as error:
        assert "IRQ allocation" in str(error)
    else:
        raise AssertionError("wrong allocated interrupt ID was accepted")
    soc.irq.locs["uart"] = 10
    constant = soc.constants["UART_INTERRUPT"]
    soc.constants["UART_INTERRUPT"] = 0
    try:
        soc.check_memory_paths()
    except ValueError as error:
        assert "BIOS IRQ constant" in str(error)
    else:
        raise AssertionError("wrong firmware interrupt ID was accepted")
    soc.constants["UART_INTERRUPT"] = constant
    soc.check_memory_paths()
    print(json.dumps(dict(result="PASS", interrupts=actual, negative_guards=2)))


if __name__ == "__main__":
    main()
