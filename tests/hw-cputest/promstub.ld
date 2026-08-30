/*
 * promstub.ld - one section at the reset vector, nothing else.
 *
 * 0xBFC00000 is KSEG1: uncached, unmapped, and where a MIPS CPU starts
 * fetching out of reset. The stub reads the suite out of the same region a few
 * kilobytes further on, and uncached is the right way to do that before
 * anything has established that the caches work.
 */

OUTPUT_FORMAT("elf32-ntradbigmips")
OUTPUT_ARCH(mips)
ENTRY(_reset)

SECTIONS
{
    . = 0xBFC00000;
    .rom : { *(.rom) }

    /DISCARD/ : {
        *(.MIPS.abiflags)
        *(.reginfo)
        *(.comment)
        *(.note*)
        *(.gnu.attributes)
        *(.pdr)
    }
}
