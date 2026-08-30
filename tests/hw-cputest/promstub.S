/*
 * promstub.S - boot the IRIS CPU test suite on this core, out of the PROM.
 *
 * WHY A PROM IMAGE AND NOT THE PROVEN PATH. docs/11 boots the suite off a SCSI
 * disk through the real PROM's ARCS loader, which is right for a real Indy and
 * awkward here: it needs the maintenance menu, and therefore a keyboard, and
 * therefore somebody sitting in front of the machine for every run. The core
 * has exactly one automatic path into memory - the framework uploads
 * games/SGIIndy/boot.rom to ioctl index 0 at core start and the CPU begins
 * fetching at 0xBFC00000 - so putting the suite there makes a run one
 * `deploy.sh --rom-only` and a relaunch.
 *
 * THE SUITE ALREADY KNOWS HOW TO BE LOADED ANYWHERE. harness/start.S takes a
 * `bal` anchor, works out its load bias, and copies [_ftext, _end) down to its
 * link address at 0x88200000 before running anything - it was written that way
 * because sashARCS loads it into kuseg, which a suite that rewrites every TLB
 * entry cannot execute from. Loaded at 0xBFC01000 the same code copies itself
 * out of the PROM into RAM, so this stub only has to jump to it.
 *
 * It copies all the way to _end, which runs off the end of the image and into
 * whatever follows in the ROM. build.sh pads with zeroes, which is what .bss
 * wants anyway.
 *
 * THE FOUR EXCEPTION VECTORS ARE THE OTHER HALF, and they are worth more than
 * the jump. The suite installs its own handlers at the BEV=0 vectors in RAM,
 * but not until main() has already probed for the test device - a read of
 * GIO64 slot 0, which is an unclaimed cycle on this machine. Anything that
 * faults before exc_install() lands here, at the BEV=1 vectors in the PROM,
 * and without these it would execute whatever bytes happen to be at that
 * offset and present as a hang. Instead each one records Cause, EPC, BadVAddr
 * and which vector it was, at a fixed uncached address the ARM can read, and
 * stops. read_log.py prints it.
 */

    .set    noreorder
    .set    noat

/* Physical 0x08180000, 1.5 MB into RAM: above the memory log at 0x08100000 and
 * below the suite's own image at 0x08200000. KSEG1 so it needs no cache flush
 * to be visible from outside the CPU. */
#define EXCREC      0xa818
#define EXCMAGIC_HI 0x4558              /* 'EX' */
#define EXCMAGIC_LO 0x4350              /* 'CP' */

/* $k0/$k1 are the kernel's to clobber, which is the whole point of them. */
.macro EXCVEC which
    lui     $26, EXCREC
    lui     $27, EXCMAGIC_HI
    ori     $27, $27, EXCMAGIC_LO
    sw      $27, 0($26)
    mfc0    $27, $13                    /* Cause    */
    nop
    sw      $27, 4($26)
    mfc0    $27, $14                    /* EPC      */
    nop
    sw      $27, 8($26)
    mfc0    $27, $8                     /* BadVAddr */
    nop
    sw      $27, 12($26)
    mfc0    $27, $12                    /* Status   */
    nop
    sw      $27, 16($26)
    ori     $27, $zero, \which
    sw      $27, 20($26)
9:  b       9b
    nop
.endm

    .section .rom, "ax"
    .globl  _reset
    .ent    _reset
_reset:
    lui     $8, 0xbfc0
    ori     $8, $8, 0x1000              /* where build.sh puts the suite */
    jr      $8
    nop
    .end    _reset

    .org    0x200
    EXCVEC  0x200                       /* TLB refill,   BEV=1 */

    .org    0x280
    EXCVEC  0x280                       /* XTLB refill,  BEV=1 */

    .org    0x300
    EXCVEC  0x300                       /* cache error,  BEV=1 */

    .org    0x380
    EXCVEC  0x380                       /* general,      BEV=1 */

    .org    0x1000                      /* the suite is concatenated here */
