/* Source: Breeze litex_wrapper/flow/system.h @ ec899c7c4367cfab56b9a6206d82066bc79f8a8b; O3 adaptation. */
#ifndef __SYSTEM_H
#define __SYSTEM_H

#ifdef __cplusplus
extern "C" {
#endif

#include <csr-defs.h>

#define csrr(reg) ({ unsigned long __tmp; \
	asm volatile ("csrr %0, " #reg : "=r"(__tmp)); \
	__tmp; })

#define csrw(reg, val) ({ \
	if (__builtin_constant_p(val) && (unsigned long)(val) < 32) \
		asm volatile ("csrw " #reg ", %0" :: "i"(val)); \
	else \
		asm volatile ("csrw " #reg ", %0" :: "r"(val)); })

#define csrs(reg, bit) ({ \
	if (__builtin_constant_p(bit) && (unsigned long)(bit) < 32) \
		asm volatile ("csrrs x0, " #reg ", %0" :: "i"(bit)); \
	else \
		asm volatile ("csrrs x0, " #reg ", %0" :: "r"(bit)); })

#define csrc(reg, bit) ({ \
	if (__builtin_constant_p(bit) && (unsigned long)(bit) < 32) \
		asm volatile ("csrrc x0, " #reg ", %0" :: "i"(bit)); \
	else \
		asm volatile ("csrrc x0, " #reg ", %0" :: "r"(bit)); })

/* O3 FENCE.I orders committed stores and invalidates local instruction state.
 * SD DMA is coherent: no software D/L2 cache maintenance is needed.
 */
__attribute__((unused)) static inline void flush_cpu_icache(void)
{
	asm volatile ("fence.i" ::: "memory");
}

__attribute__((unused)) static inline void flush_cpu_dcache(void)
{
	asm volatile ("fence rw, rw" ::: "memory");
}

void flush_l2_cache(void);
void busy_wait(unsigned int ms);
void busy_wait_us(unsigned int us);

#ifdef __cplusplus
}
#endif

#endif /* __SYSTEM_H */
