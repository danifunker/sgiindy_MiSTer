/*
 * start.S - bootstrap for dmatest.
 *
 * tests/int/start.S with the exception trampoline removed: this image polls
 * the DMA channel's control register and never arms an interrupt, so there is
 * no handler to install. The harness loads it straight into RAM and starts the
 * CPU at _start, so there is no PROM and no relocation.
 *
 * Numeric register names throughout. o32 and n32 disagree about which hardware
 * register each $tN means, and under n32 $t4-$t7 do not exist at all, so the
 * names are the one thing that must not be used here.
 */
    .set noreorder
    .set noat
    .section .init, "ax"
    .globl _start
    .ent _start
_start:
    /* Kernel mode, 64-bit addressing off, CU1 on, BEV off - so exceptions go
     * to the RAM vector at 0x80000180 rather than the PROM's at 0xBFC00380.
     * IE stays off and every IM bit stays clear: the DMA interrupt is checked
     * by reading INT2's status register, not by taking an exception. */
    li      $8, 0x30000000
    mtc0    $8, $12                 /* Status */
    nop
    mtc0    $0, $13                 /* Cause */
    nop

    /* Zero .bss. */
    la      $8, _fbss
    la      $9, _end
1:  sltu    $10, $8, $9
    beq     $10, $0, 2f
    nop
    sw      $0, 0($8)
    b       1b
    addiu   $8, $8, 4
2:
    la      $29, _stack_top         /* $sp */
    la      $28, _gp                /* $gp */
    jal     main
    nop
3:  b       3b
    nop
    .end _start
