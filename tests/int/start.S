/*
 * start.S - bootstrap and exception vector for inttest.
 *
 * Same shape as tests/scc/start.S - the harness loads this straight into RAM
 * and starts the CPU at _start, so there is no PROM and no relocation - with
 * one addition: a trampoline for the general exception vector.
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
     * IE stays off and every IM bit stays clear: main() turns on exactly the
     * one line each test is about, which is what makes a spurious interrupt
     * from some other source a failure rather than a pass. */
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

/*
 * The trampoline copied to 0x80000180 by exc_install(). The vector slot is
 * only 128 bytes, so it does nothing but jump to the real handler in the
 * image. $k0 and $k1 are the two registers the architecture reserves for
 * exactly this, so nothing has to be saved before the jump.
 */
    .text
    .globl tramp_general
    .globl tramp_general_end
tramp_general:
    lui     $26, %hi(exc_entry)
    addiu   $26, $26, %lo(exc_entry)
    jr      $26
    nop
tramp_general_end:

/*
 * exc_entry - the handler.
 *
 * It runs with EXL set, which is what keeps it from being re-entered by the
 * interrupt it is here to service: EXL masks every interrupt regardless of IE
 * and IM, and eret clears it. So there is no window here, and nothing has to
 * be masked by hand.
 *
 * It calls into C, which means it has to look like a caller: n32 leaves $sp
 * and $gp alone across a call, and the interrupted code's $sp is a perfectly
 * good stack as long as this does not run on the very first instruction of a
 * function. It cannot: the tests spin in a loop with a valid frame.
 */
    .globl exc_entry
    .ent exc_entry
exc_entry:
    addiu   $29, $29, -128
    sd      $2,  0($29)
    sd      $3,  8($29)
    sd      $4,  16($29)
    sd      $5,  24($29)
    sd      $6,  32($29)
    sd      $7,  40($29)
    sd      $8,  48($29)
    sd      $9,  56($29)
    sd      $10, 64($29)
    sd      $11, 72($29)
    sd      $12, 80($29)
    sd      $13, 88($29)
    sd      $14, 96($29)
    sd      $15, 104($29)
    sd      $31, 112($29)

    jal     exc_handler
    nop

    ld      $2,  0($29)
    ld      $3,  8($29)
    ld      $4,  16($29)
    ld      $5,  24($29)
    ld      $6,  32($29)
    ld      $7,  40($29)
    ld      $8,  48($29)
    ld      $9,  56($29)
    ld      $10, 64($29)
    ld      $11, 72($29)
    ld      $12, 80($29)
    ld      $13, 88($29)
    ld      $14, 96($29)
    ld      $15, 104($29)
    ld      $31, 112($29)
    addiu   $29, $29, 128

    eret
    nop
    .end exc_entry
