#ifndef __O3_IRQ_H
#define __O3_IRQ_H
#include <system.h>
#include <generated/soc.h>

/* Raw one-based PLIC IDs equal LiteX's generated IRQ numbers. */
#define PLIC_BASE O3_PLIC_BASE
#define PLIC_PENDING (PLIC_BASE + 0x1000UL)
#define PLIC_ENABLED (PLIC_BASE + 0x2000UL)
#define PLIC_THRSHLD (PLIC_BASE + 0x200000UL)
#define PLIC_CLAIM (PLIC_BASE + 0x200004UL)
#define PLIC_EXT_IRQ_BASE 0

static inline unsigned int irq_getie(void)
{ return (csrr(mstatus) & CSR_MSTATUS_MIE) != 0; }
static inline void irq_setie(unsigned int ie)
{ if (ie) csrs(mstatus, CSR_MSTATUS_MIE); else csrc(mstatus, CSR_MSTATUS_MIE); }
static inline unsigned int irq_getmask(void)
{ return *((volatile unsigned int *)PLIC_ENABLED); }
static inline void irq_setmask(unsigned int mask)
{ *((volatile unsigned int *)PLIC_ENABLED) = mask & O3_PLIC_MASK; }
static inline unsigned int irq_pending(void)
{ return *((volatile unsigned int *)PLIC_PENDING); }
#endif
