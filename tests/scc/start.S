/*
 * start.S - minimal bootstrap for scctest.
 *
 * The harness loads this straight into RAM and starts the CPU at _start, so
 * there is no PROM to have set anything up and no relocation to do: the image
 * is linked at the address it is loaded to.
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
    /* Kernel mode, 64-bit addressing off, CU1 on, interrupts off, BEV off.
     * CU1 is set because the compiler may not emit FP but the CPU should be
     * in the state the PROM leaves it in. */
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
