/* Linked at KSEG0 0x88200000 - physical 0x08200000, two megabytes into RAM.
 * Same address as the cpu-tests suite, and for the same reason: physical RAM
 * on IP22/IP24 starts at 0x08000000, the bottom 512 KB is an alias of it that
 * holds the exception vectors, and 0x80200000 is a hole that swallows writes.
 * See cpu-tests/docs/memory-map.md. */
OUTPUT_FORMAT("elf32-ntradbigmips")
OUTPUT_ARCH(mips)
ENTRY(_start)

SECTIONS
{
    . = 0x88200000;
    .init   : { *(.init) }
    .text   : { *(.text) *(.text.*) }
    . = ALIGN(16);
    .rodata : { *(.rodata) *(.rodata.*) }
    .data   : { *(.data) *(.data.*) }
    _gp = ALIGN(16) + 0x7ff0;
    . = ALIGN(16);
    _fbss = .;
    .bss    : {
        *(.bss) *(.bss.*) *(COMMON) *(.sbss) *(.scommon)
        . = ALIGN(16);
        . += 0x4000;
        _stack_top = .;
    }
    _end = .;
    /DISCARD/ : { *(.MIPS.abiflags) *(.reginfo) *(.comment) *(.note*)
                  *(.gnu.attributes) *(.pdr) *(.eh_frame) }
}
