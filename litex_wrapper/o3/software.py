"""Per-build official LiteX BIOS adaptations; installed packages stay untouched."""
import hashlib
import json
import re
import shutil
from pathlib import Path

from .platform import load_platform


def prepare_software(builder):
    import litex.soc.integration.builder as upstream
    config = load_platform()
    overlay = Path(builder.output_dir) / "software-source"
    overlay.mkdir(parents=True, exist_ok=True)
    recorded = {}
    for package in ("libbase", "liblitesdcard"):
        source = Path(upstream.soc_directory) / "software" / package
        dest = overlay / package
        shutil.copytree(source, dest, dirs_exist_ok=True)
        recorded[package] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                             for p in sorted(source.glob("*")) if p.is_file()}
        builder.software_packages = [(n, str(dest) if n == package else path)
                                     for n, path in builder.software_packages]

    # Official PLIC ISR uses the header's raw IDs. Initialize the wired IDs,
    # rather than the official default's first eight sources.
    path = overlay / "libbase/isr.c"
    text = path.read_text()
    pattern = r"void plic_init\(void\)\s*\{.*?\n\}"
    body = """void plic_init(void)
{
    for (unsigned int i = 1; i <= O3_PLIC_NUM_SOURCES; ++i)
        ((volatile unsigned int *)PLIC_BASE)[i] = (O3_PLIC_MASK & (1U << i)) ? 1 : 0;
    *((volatile unsigned int *)PLIC_ENABLED) = O3_PLIC_MASK;
    *((volatile unsigned int *)PLIC_THRSHLD) = 0;
}"""
    # Patch only the generic __riscv_plic__ section, not other CPU backends.
    begin = text.index("#if defined(__riscv_plic__)\n")
    end = text.index("#elif", begin)
    section, count = re.subn(pattern, body, text[begin:end], count=1, flags=re.S)
    if count != 1:
        raise RuntimeError("official LiteX PLIC initialization changed; inspect before building")
    path.write_text(text[:begin] + section + text[end:])

    # DMA bridge accepts only DDR. Use an aligned reserved DDR sector for
    # BIOS SRAM/unaligned buffers, retaining the official driver underneath.
    path = overlay / "liblitesdcard/sdcard.c"
    text = path.read_text()
    declaration = re.compile(r"static uint8_t sdcard_switch_status\[64\].*?;")
    scratch = int(config["sdcard"]["biosScratchOrigin"], 0)
    text, count = declaration.subn(f"#define sdcard_switch_status ((uint8_t *)(uintptr_t)0x{scratch + 0x200:x}UL)", text)
    if count != 1:
        raise RuntimeError("official SD switch-status declaration changed")
    # sizeof(pointer) would be wrong after moving this array to DDR.
    text = text.replace("sizeof(sdcard_switch_status)", "64")
    for name in ("read", "write"):
        text, count = re.subn(rf"\bint sdcard_{name}\(uint32_t block, uint32_t count, uint8_t\* buf\)",
                              f"static int o3_sdcard_{name}_direct(uint32_t block, uint32_t count, uint8_t* buf)", text)
        if count != 1:
            raise RuntimeError(f"official sdcard_{name} signature changed")
    marker = "/* SDCard FatFs disk functions"
    at = text.index(marker)
    # Insert before the preceding section comment, after both DMA functions.
    at = text.rfind("/*---", 0, at)
    wrapper = r"""
static int o3_sdcard_transfer(uint32_t block, uint32_t count, uint8_t *buf, int write)
{
    uintptr_t start = (uintptr_t)buf;
    uint64_t finish = (uint64_t)start + (uint64_t)count * 512;
    uint8_t *bounce = (uint8_t *)(uintptr_t)O3_SD_SCRATCH_BASE;
    if (count == 0) return SD_OK;
    if (start >= MAIN_RAM_BASE && finish <= (uint64_t)MAIN_RAM_BASE + MAIN_RAM_SIZE && !(start & 7)) {
        __asm__ __volatile__("fence rw, rw" ::: "memory");
        int status = write ? o3_sdcard_write_direct(block, count, buf) : o3_sdcard_read_direct(block, count, buf);
        __asm__ __volatile__("fence rw, rw" ::: "memory");
        return status;
    }
    while (count--) {
        if (write) memcpy(bounce, buf, 512);
        __asm__ __volatile__("fence rw, rw" ::: "memory");
        int status = write ? o3_sdcard_write_direct(block, 1, bounce) : o3_sdcard_read_direct(block, 1, bounce);
        __asm__ __volatile__("fence rw, rw" ::: "memory");
        if (status != SD_OK) return status;
        if (!write) memcpy(buf, bounce, 512);
        ++block; buf += 512;
    }
    return SD_OK;
}
int sdcard_read(uint32_t block, uint32_t count, uint8_t *buf)
{ return o3_sdcard_transfer(block, count, buf, 0); }
int sdcard_write(uint32_t block, uint32_t count, uint8_t *buf)
{ return o3_sdcard_transfer(block, count, buf, 1); }

"""
    text = text[:at] + wrapper + text[at:]
    path.write_text(text)
    (overlay / "upstream-sha256.json").write_text(json.dumps(recorded, indent=2) + "\n")
