/* Simulation-only BIOS command. Real O3 traps, CLINT and PLIC/UART CSR path. */
#include <stdint.h>
#include <stdio.h>
#include <system.h>
#include <generated/csr.h>
#include <generated/mem.h>
#include "command.h"

volatile unsigned long o3_test_cause __attribute__((used));
volatile unsigned long o3_test_tval __attribute__((used));
volatile unsigned long o3_test_traps __attribute__((used));

/* Only t0/t1 are scratch; no C calls, no ABI-dependent compiler prologue.
 * Fault probes use explicit 32-bit instructions, so mepc advances by four.
 * Interrupt probes preserve mepc and disable mie until software inspects them.
 */
__asm__(
    ".text\n.balign 4\n.global o3_test_trap\no3_test_trap:\n"
    "addi sp, sp, -16\nsd t0, 0(sp)\nsd t1, 8(sp)\n"
    "csrr t0, mcause\nla t1, o3_test_cause\nsd t0, 0(t1)\n"
    "csrr t0, mtval\nla t1, o3_test_tval\nsd t0, 0(t1)\n"
    "la t1, o3_test_traps\nld t0, 0(t1)\naddi t0, t0, 1\nsd t0, 0(t1)\n"
    "csrr t0, mcause\nbltz t0, 1f\n"
    "csrr t0, mepc\naddi t0, t0, 4\ncsrw mepc, t0\nj 2f\n"
    "1: csrw mie, zero\n"
    "2: ld t0, 0(sp)\nld t1, 8(sp)\naddi sp, sp, 16\nmret\n");
extern void o3_test_trap(void);

static volatile uint64_t *const mtime = (void *)(uintptr_t)0x0200bff8;
static volatile uint64_t *const mtimecmp = (void *)(uintptr_t)0x02004000;

static int wait_trap(unsigned long before)
{
    for (unsigned int i = 0; i < 100000; ++i)
        if (o3_test_traps != before) return 1;
    return 0;
}

static void soc_selftest_handler(int count, char **params)
{
    (void)count; (void)params;
    unsigned long old_vec = csrr(mtvec), old_ie = csrr(mie), old_status = csrr(mstatus);
    unsigned int old_uart = uart_ev_enable_read();
    int ok = 1;
    csrw(mie, 0);
    csrw(mtvec, (uintptr_t)o3_test_trap);
    o3_test_traps = 0;
    uint64_t first = *mtime;
    for (unsigned int i = 0; i < 10000 && *mtime == first; ++i) {}
    if (*mtime <= first) ok = 0;
    else puts("[O3-S2] CLINT mtime PASS");

    *mtimecmp = *mtime + 10;
    csrw(mie, 1UL << 7);
    csrs(mstatus, 8);
    if (!wait_trap(0) || o3_test_cause != ((1UL << 63) | 7)) ok = 0;
    else puts("[O3-S2] MTIP trap PASS");
    csrw(mie, 0);
    *mtimecmp = UINT64_MAX;

    /* TX ready is a real level event from the UART FIFO, wired to source 10.
     * Claim/complete uses the M-context registers, not a test interrupt pin.
     */
    volatile uint32_t *priority = (void *)(uintptr_t)(PLIC_BASE + 10*4);
    volatile uint32_t *enabled = (void *)(uintptr_t)(PLIC_BASE + 0x2000);
    volatile uint32_t *threshold = (void *)(uintptr_t)(PLIC_BASE + 0x200000);
    volatile uint32_t *claim = (void *)(uintptr_t)(PLIC_BASE + 0x200004);
    uint32_t old_priority = *priority, old_enabled = *enabled, old_threshold = *threshold;
    *priority = 1; *enabled = 1U << 10; *threshold = 0;
    uart_ev_enable_write(1);
    unsigned long before = o3_test_traps;
    csrw(mie, 1UL << 11);
    int irq_seen = wait_trap(before);
    csrw(mie, 0);
    uint32_t id = *claim;
    uart_ev_enable_write(0);
    if (id) *claim = id;
    if (!irq_seen || o3_test_cause != ((1UL << 63) | 11) || id != 10) ok = 0;
    else puts("[O3-S2] UART PLIC claim=10 complete PASS");
    *priority = old_priority; *enabled = old_enabled; *threshold = old_threshold;

    before = o3_test_traps;
    uintptr_t hole = 0x12100000;
    unsigned long ignored;
    __asm__ volatile(".option push\n.option norvc\nld %0, 0(%1)\n.option pop"
        : "=r"(ignored) : "r"(hole) : "memory");
    if (o3_test_traps != before+1 || o3_test_cause != 5 || o3_test_tval != hole) ok = 0;
    else puts("[O3-S2] hole load cause=5 mtval=12100000 PASS");

    before = o3_test_traps;
    uintptr_t rom = ROM_BASE;
    uint64_t original = *(volatile uint64_t *)rom;
    __asm__ volatile(".option push\n.option norvc\nsd zero, 0(%0)\n.option pop"
        : : "r"(rom) : "memory");
    if (o3_test_traps != before+1 || o3_test_cause != 7 || o3_test_tval != rom ||
            *(volatile uint64_t *)rom != original) ok = 0;
    else puts("[O3-S2] ROM store cause=7 unchanged PASS");

    csrw(mie, 0);
    csrw(mtvec, old_vec);
    uart_ev_enable_write(old_uart);
    csrw(mie, old_ie);
    csrw(mstatus, old_status);
    puts(ok ? "[O3-S2] ALL PASS" : "[O3-S2] FAIL");
}
define_command_args(soc_selftest, soc_selftest_handler, "O3 simulation S2 checks",
    "soc_selftest", 0, 0, SYSTEM_CMDS);
