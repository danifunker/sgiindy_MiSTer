/* Everything in one PT_LOAD at a KSEG0 address inside RAM.
 *
 * The harness's ELF loader maps vaddr -> physical by stripping KSEG0/KSEG1 and
 * refuses anything outside [0x08000000, RAM end). ld's default script emits
 * .reginfo/.MIPS.abiflags/.data at their own default addresses, which lands a
 * segment at 0x00400000 and gets the load rejected - so the layout is spelled
 * out here rather than left to the default. */
OUTPUT_FORMAT("elf32-tradbigmips")
OUTPUT_ARCH(mips)
ENTRY(_start)

/* One loadable segment, explicitly. Without this ld maps the ELF headers
 * themselves as a second PT_LOAD at its default 0x00400000, which is outside
 * RAM and the harness rejects the whole file. */
PHDRS { text PT_LOAD FLAGS(7); }

SECTIONS
{
    . = 0x88001000;

    .text : {
        *(.text)
        *(.text.*)
        *(.rodata)
        *(.rodata.*)
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
    } :text

    .bss : { *(.bss) *(.bss.*) *(.sbss) *(.sbss.*) *(COMMON) } :text

    /* Metadata the loader must never see as a loadable segment. */
    /DISCARD/ : {
        *(.reginfo)
        *(.MIPS.abiflags)
        *(.pdr)
        *(.comment)
        *(.gnu.attributes)
    }
}
