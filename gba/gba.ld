/* gba.ld — раскладка GBA ROM: 0x00 entry, 0x04 логотип, 0xA0 поля,
 * 0xC0 код; .data/.bss — в EWRAM 0x02002000 (загрузка с ROM: crt0
 * копирует/чистит по символам); лог 0x02000000, куча 0x02010000. */
OUTPUT_FORMAT("elf32-littlearm")
ENTRY(_start)

SECTIONS {
    . = 0x08000000;
    .text.start : { *(.text.start) }
    . = 0x08000004;
    .text.logo : { *(.text.logo) }
    . = 0x080000A0;
    .text.hdr : { *(.text.hdr) }
    . = 0x080000C0;
    .text : { *(.text.boot) *(.text*) }
    .rodata : { *(.rodata*) }
    . = ALIGN(4);
    __data_rom = .;
    . = 0x02002000;
    .data : AT(__data_rom) { __data_start = .; *(.data*) __data_end = .; }
    __bss_start = .;
    .bss (NOLOAD) : { *(.bss*) *(.COMMON) }
    __bss_end = .;
}

/* unwind-метаданные не нужны (bare metal) */
SECTIONS { /DISCARD/ : { *(.ARM.exidx*) *(.ARM.attributes) *(.comment) } }
