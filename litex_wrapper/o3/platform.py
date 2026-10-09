"""O3 platform configuration shared by RTL generation and LiteX integration."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load_platform(path=None):
    config = json.loads(Path(path or ROOT / "config/o3_platform.json").read_text())
    if config["addressWidth"] != 32:
        raise ValueError("O3 v1 requires 32-bit memory addresses")
    regions = []
    for item in config["regions"]:
        r = dict(item, origin=int(item["origin"], 0), size=int(item["size"], 0))
        if r["size"] <= 0 or r["origin"] < 0 or r["origin"] + r["size"] > 2**32:
            raise ValueError(f"invalid region {r['name']}")
        # LiteX rounds decoder sizes up to a power of two. Reject such
        # widening rather than letting the decoder differ from the PMA.
        if r["size"] & (r["size"] - 1) or r["origin"] % r["size"]:
            raise ValueError(f"region must have power-of-two size and aligned origin: {r['name']}")
        if r["amo"] not in ("none", "arithmetic") or r["reservability"] not in ("none", "eventual"):
            raise ValueError(f"unsupported PMA attributes: {r['name']}")
        regions.append(r)
    if len({r["name"] for r in regions}) != len(regions):
        raise ValueError("duplicate region name")
    ordered = sorted(regions, key=lambda r: r["origin"])
    for a, b in zip(ordered, ordered[1:]):
        if a["origin"] + a["size"] > b["origin"]:
            raise ValueError("overlapping PMA regions")
    pages = config["mmioPages"]
    csr = next(r for r in regions if r["name"] == "litex_mmio")
    csr_address_width(config)
    used = set()
    for p in pages:
        start, size = int(p["origin"], 0), int(p["size"], 0)
        if size != 0x1000 or (start - csr["origin"]) % size or not (
            csr["origin"] <= start < start + size <= csr["origin"] + csr["size"]
        ) or start in used:
            raise ValueError(f"invalid CSR page {p['name']}")
        used.add(start)
    ids = [s["plicId"] for s in config["externalInterrupts"]["sources"]]
    if len(ids) != len(set(ids)) or any(not 1 <= i <= config["externalInterrupts"]["numSources"] for i in ids):
        raise ValueError("invalid PLIC allocation")
    sd = config["sdcard"]
    main = next(r for r in regions if r["name"] == "main_ram")
    scratch, size = int(sd["biosScratchOrigin"], 0), int(sd["biosScratchSize"], 0)
    if sd["dmaRegion"] != "main_ram" or sd["dmaDataWidth"] != 64 or sd["mode"] != "read+write":
        raise ValueError("O3 SD DMA requires 64-bit read/write DMA into main_ram")
    if scratch % 64 or size < 0x240 or not main["origin"] <= scratch < scratch + size <= main["origin"] + main["size"]:
        raise ValueError("invalid BIOS SD scratch memory")
    return config


def platform_regions(root=None, *, config=None):
    if config is None:
        config = load_platform(None if root is None else Path(root) / "config/o3_platform.json")
    return {r["name"]: dict(r, origin=int(r["origin"], 0), size=int(r["size"], 0))
            for r in config["regions"]}


def csr_map(config):
    origin = platform_regions(config=config)["litex_mmio"]["origin"]
    return {p["name"]: (int(p["origin"], 0) - origin) // 0x1000 for p in config["mmioPages"]}


def csr_address_width(config):
    """LiteX CSR addresses count 32-bit words, not Wishbone's 64-bit words."""
    region = platform_regions(config=config)["litex_mmio"]
    size = region["size"]
    if size <= 0 or size & (size - 1) or region["origin"] % size:
        raise ValueError("CSR window must have power-of-two size and aligned origin")
    width = size.bit_length() - 1 - 2
    if width not in range(14, 19):
        raise ValueError("CSR window requires unsupported LiteX address width (supported: 14..18)")
    return width


def irq_map(config):
    return {s["name"]: s["plicId"] for s in config["externalInterrupts"]["sources"]}
