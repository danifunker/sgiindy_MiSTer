/*
 * tlborder.S - the delay-slot store that IRIX loses, in forty instructions.
 *
 * WHY THIS EXISTS. The failure it reproduces takes a 25-minute IRIX boot to
 * reach, and four attempts at fixing it were each a 35-minute round trip. It
 * is reproducible in about a second, and cpu-tests cannot host it: that suite
 * runs from KSEG0, which is unmapped, so its instruction fetches never miss
 * the TLB and the condition here cannot arise.
 *
 * THE CONDITION. A branch whose delay slot is a store, where the branch
 * TARGET's page and the STORE's page both miss the TLB:
 *
 *      jal   target          <- target page is invalid: the FETCH faults
 *      sw    v0, 0(at)       <- delay slot, at an invalid page: the STORE faults
 *
 * The fetch stage runs ahead of execute, and `EXETLBDataAccess` is gated on
 * `stall = 0`, so the store cannot even ASK for its translation while the
 * fetch is stalled on its own walk. The fetch-side fault is therefore always
 * accepted first and sets EXL; the store's own fault then arrives to find EXL
 * set and - by the R4000 nested-exception rule - its EPC write is discarded.
 *
 *   CORRECT:  EPC = the JAL, Cause.BD = 1, ExcCode = TLBS(3), BadVAddr = store
 *   BROKEN:   EPC = the branch TARGET, Cause.BD = 0
 *
 * Software returns to the branch target, the delay slot never runs again, and
 * a store is silently lost. See docs/25-lost-store-tlb-order.md.
 *
 * HOW TO READ THE RESULT. The handler parks in a spin loop; the answer comes
 * out of the harness, which prints EPC and Cause for every exception:
 *
 *   make -C verilator wholemachine
 *   tests/tlborder/build.sh
 *   ./verilator/obj_wm/Vsim_top --elf tests/out/tlborder/tlborder.elf \
 *        --no-gfx --exc --exc-count 8 --epc --epc-count 8 --max-cycles 300000
 *
 * The addresses are deliberately in kuseg (below 0x80000000) so that this also
 * exercises the user-mode half of the fix's guard.
 */

    .set    noreorder
    .set    noat
    .set    mips3

/* CP0 registers */
#define C0_INDEX    $0
#define C0_ENTRYLO0 $2
#define C0_ENTRYLO1 $3
#define C0_PAGEMASK $5
#define C0_ENTRYHI  $10
#define C0_STATUS   $12
#define C0_CAUSE    $13
#define C0_EPC      $14

/* Where the test's own code is mapped, and the two pages that must fault. */
#define VA_CODE     0x00400000
#define VA_TARGET   0x00500000
#define VA_STORE    0x00600000

/* A physical page to back VA_CODE with. Physical, not KSEG0: EntryLo wants a
 * PFN. 0x08040000 is well clear of this program, which loads at 0x08001000. */
#define PA_CODE     0x08040000

    .text
    .globl  _start
_start:
    /* Status = 0: BEV clear (so exceptions go to 0x80000180, not the PROM),
     * EXL clear, interrupts off, kernel mode. */
    mtc0    $0, C0_STATUS
    nop
    mtc0    $0, C0_PAGEMASK         /* 4 KB pages */
    nop

    /* ---- install the handler at 0x80000180 -------------------------------
     * It cannot be linked there: 0x80000180 is physical 0x180, below the RAM
     * base, so the ELF loader refuses it. Writing it is fine - the bottom
     * 512 KB is an alias of the bottom of memory. */
    li      $8, 0x80000180
    lui     $9, %hi(handler_word)
    ori     $9, $9, %lo(handler_word)
    lw      $10, 0($9)
    sw      $10, 0($8)              /* b . */
    lw      $10, 4($9)
    sw      $10, 4($8)              /* nop (delay slot) */

    /* ---- park every TLB entry somewhere harmless -------------------------
     * Reset leaves them undefined; a stray VPN2 of 0 would match the test's
     * own addresses and hide the fault. */
    li      $8, 0                   /* index */
    li      $9, 0x7FE00000          /* a VPN2 nothing here uses */
1:
    mtc0    $8, C0_INDEX
    mtc0    $9, C0_ENTRYHI
    mtc0    $0, C0_ENTRYLO0         /* V=0 */
    mtc0    $0, C0_ENTRYLO1
    nop
    tlbwi
    nop
    addiu   $8, $8, 1
    addiu   $9, $9, 0x2000          /* next VPN2 pair */
    slti    $10, $8, 48
    bne     $10, $0, 1b
    nop

    /* ---- copy the faulting snippet into PA_CODE -------------------------- */
    lui     $8, %hi(snippet)
    ori     $8, $8, %lo(snippet)
    lui     $9, %hi(snippet_end)
    ori     $9, $9, %lo(snippet_end)
    /* KSEG1 (uncached), not KSEG0. The copy is data and the snippet is then
     * FETCHED, and there is no cache coherence between the two: with a KSEG0
     * destination the words sat in the D-cache, the I-cache read the stale
     * memory underneath - all zeroes, which decode as nops - and the test
     * quietly executed 8 KB of nops off the end of its own mapping and
     * faulted on 0x00402000 instead of on the pair it exists to test. */
    li      $10, 0xA8040000         /* KSEG1 (uncached) view of PA_CODE */
2:
    lw      $11, 0($8)
    sw      $11, 0($10)
    addiu   $8, $8, 4
    addiu   $10, $10, 4
    sltu    $12, $8, $9
    bne     $12, $0, 2b
    nop

    /* ---- entry 0: VA_CODE -> PA_CODE, valid, dirty, global --------------- */
    li      $8, 0
    mtc0    $8, C0_INDEX
    li      $9, VA_CODE
    mtc0    $9, C0_ENTRYHI
    /* EntryLo = PFN<<6 | cache(3)<<3 | D | V | G.  PFN = PA >> 12.
     * cache 3 = cacheable non-coherent. */
    li      $10, ((PA_CODE >> 12) << 6) | (3 << 3) | 0x7
    mtc0    $10, C0_ENTRYLO0
    li      $10, (((PA_CODE + 0x1000) >> 12) << 6) | (3 << 3) | 0x7
    mtc0    $10, C0_ENTRYLO1
    nop
    tlbwi
    nop

    /* ---- entry 1: VA_TARGET, INVALID - the fetch will fault -------------- */
    li      $8, 1
    mtc0    $8, C0_INDEX
    li      $9, VA_TARGET
    mtc0    $9, C0_ENTRYHI
    li      $10, ((PA_CODE >> 12) << 6) | (3 << 3) | 0x1   /* G only, V=0 */
    mtc0    $10, C0_ENTRYLO0
    mtc0    $10, C0_ENTRYLO1
    nop
    tlbwi
    nop

    /* ---- entry 2: VA_STORE, INVALID - the store will fault --------------- */
    li      $8, 2
    mtc0    $8, C0_INDEX
    li      $9, VA_STORE
    mtc0    $9, C0_ENTRYHI
    li      $10, ((PA_CODE >> 12) << 6) | (3 << 3) | 0x1   /* G only, V=0 */
    mtc0    $10, C0_ENTRYLO0
    mtc0    $10, C0_ENTRYLO1
    nop
    tlbwi
    nop

    /* EntryHi back to the code ASID/VPN so nothing stale matches. */
    li      $9, VA_CODE
    mtc0    $9, C0_ENTRYHI
    nop

    /* ---- go ------------------------------------------------------------- */
    li      $8, VA_CODE
    jr      $8
    nop

/* --------------------------------------------------------------------------
 * The snippet, copied to PA_CODE and executed at VA_CODE. Keep it position-
 * independent in the sense that matters: the `jal` target is an absolute
 * 26-bit address in region 0, which VA_TARGET is.
 * ------------------------------------------------------------------------ */
    .align  4
snippet:
    lui     $1, %hi(VA_STORE)       /* at = the invalid data page          */
    ori     $1, $1, %lo(VA_STORE)
    li      $2, 0x5A5A5A5A
    nop
    jal     VA_TARGET               /* target page invalid: FETCH faults   */
    sw      $2, 0($1)               /* delay slot, page invalid: STORE faults */
    nop
    nop
snippet_end:

/* The two words copied to 0x80000180: an infinite loop. The harness reports
 * EPC and Cause for every exception, so the handler has nothing to do. */
    .align  4
handler_word:
    b       .
    nop
