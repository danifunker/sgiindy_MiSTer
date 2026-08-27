"""SGI IP22/IP24 (Indy / Indigo2) physical address map + register names.

Addresses are given as PHYSICAL. The PROM reaches them through kseg1
(uncached, phys | 0xa0000000) and occasionally kseg0 (phys | 0x80000000).
"""

# ---- coarse regions: (start, end, name, note) ----
REGIONS = [
    (0x00000000, 0x08000000, "EISA/GIO low",      "GIO64 / EISA slot space (Indigo2); unused on Indy"),
    (0x08000000, 0x10000000, "MAIN_MEMORY",       "Main DRAM base. IP22/IP24 RAM always starts at phys 0x08000000"),
    (0x10000000, 0x1f000000, "GIO64",             "GIO64 expansion bus slot windows"),
    (0x1f000000, 0x1f0f0000, "GFX_LOW",           "Graphics board low window (VC1/XMAP/DAC on GR2)"),
    (0x1f0f0000, 0x1f100000, "REX",                "GR2/Newport REX rendering engine "
                                                   "(XSTART +0x100, XSTARTI +0x148, CONFIG +0x1330)"),
    (0x1f100000, 0x1f400000, "GFX",                "Graphics board remaining windows"),
    (0x1f400000, 0x1f600000, "GIO_SLOT1",         "GIO expansion slot 1"),
    (0x1f600000, 0x1f800000, "GIO_SLOT0",         "GIO expansion slot 0"),
    (0x1fa00000, 0x1fa20000, "MC",                "Memory / GIO64 arbiter controller"),
    (0x1fb00000, 0x1fb80000, "HPC3_ALIAS",        "HPC3 alias / GIO"),
    (0x1fb80000, 0x1fc00000, "HPC3",              "HPC3 peripheral controller chip 0"),
    (0x1fc00000, 0x1fc80000, "PROM",              "512 KiB boot PROM (this image)"),
    (0x1fc80000, 0x20000000, "PROM_ALIAS",        "PROM address aliases"),
]

# ---- MC: Memory Controller, phys 0x1fa00000 ------------------------------
# Registers are architecturally 64-bit; the PROM accesses the low half at +4.
MC_BASE = 0x1fa00000
MC = {
 0x0000: ("MC_CPUCTRL0",   "CPU control 0: refresh, endian, parity, GIO/EISA enables, watchdog"),
 0x0008: ("MC_CPUCTRL1",   "CPU control 1: bus-error/timeouts, POR/graphics reset"),
 0x0010: ("MC_WATCHDOG",   "Watchdog timer: any write clears/pets it"),
 0x0018: ("MC_SYSID",      "System ID: board revision + chip revision (read-only)"),
 0x0028: ("MC_RPSS_DIV",   "RPSS 100 ns counter divider / increment"),
 0x0030: ("MC_EEPROM",     "Serial EEPROM bit-bang: CS / SCK / DATA-out / DATA-in"),
 0x0040: ("MC_REF_CTR",    "Refresh counter preload"),
 0x0048: ("MC_REF_TIMER",  "Refresh timer"),
 0x0080: ("MC_RPSS_CTR",   "RPSS free-running counter (100 ns tick)"),
 0x00c0: ("MC_MEMCFG0",    "Memory bank config, banks 0/1 (base, size, valid, subbank)"),
 0x00c8: ("MC_MEMCFG1",    "Memory bank config, banks 2/3"),
 0x00d0: ("MC_CPU_MEMACC", "CPU memory access config (timing)"),
 0x00d8: ("MC_GIO_MEMACC", "GIO memory access config (timing)"),
 0x00e0: ("MC_CPU_ERRADDR","CPU bus-error address"),
 0x00e8: ("MC_CPU_ERRSTAT","CPU bus-error status"),
 0x00f0: ("MC_GIO_ERRADDR","GIO bus-error address"),
 0x00f8: ("MC_GIO_ERRSTAT","GIO bus-error status"),
 0x0100: ("MC_SYS_SEMAPHORE","System semaphore (test-and-set)"),
 0x0108: ("MC_GIO_LOCK",   "GIO bus lock"),
 0x0110: ("MC_EISA_LOCK",  "EISA bus lock"),
 0x0150: ("MC_GIO64_ARB",  "GIO64 arbiter configuration"),
 0x0158: ("MC_ARB_CPU_TIME","GIO64 arbiter CPU time slice"),
 0x0160: ("MC_ARB_BURST",  "GIO64 arbiter long-burst time"),
 0x0168: ("MC_ARB_?",      "GIO64 arbiter (undocumented slot)"),
 0x0180: ("MC_MEM_PARITY", "Memory parity error address/control"),
 0x0188: ("MC_MEM_PARITY1","Memory parity (second word)"),
 0x1000: ("MC_GDMA_CTRL",  "GIO DMA control"),
 0x2000: ("MC_DMA_MEMADDR","GIO DMA: memory address"),
 0x2008: ("MC_DMA_LCOUNT", "GIO DMA: line count / width"),
 0x2010: ("MC_DMA_GIOADDR","GIO DMA: GIO bus address"),
 0x2018: ("MC_DMA_MODE",   "GIO DMA: mode (direction, sync, burst)"),
 0x2020: ("MC_DMA_ZCNT",   "GIO DMA: zoom / byte count"),
 0x2028: ("MC_DMA_START",  "GIO DMA: start (write triggers)"),
 0x2030: ("MC_DMA_RUN",    "GIO DMA: run / status"),
 0x2038: ("MC_DMA_GIO64",  "GIO DMA: 64-bit control"),
 0x2040: ("MC_DMA_STRIDE", "GIO DMA: stride"),
 0x2048: ("MC_DMA_?",      "GIO DMA (undocumented slot)"),
}

# ---- HPC3: phys 0x1fb80000 ----------------------------------------------
HPC3_BASE = 0x1fb80000
HPC3 = {
 0x0000: ("HPC3_SCSI0_DESC",  "SCSI channel 0 DMA descriptor / cbp / nbdp"),
 0x0004: ("HPC3_SCSI0_CBP",   "SCSI 0 current buffer pointer"),
 0x0008: ("HPC3_SCSI0_NBDP",  "SCSI 0 next buffer descriptor pointer"),
 0x0010: ("HPC3_SCSI0_CTRL",  "SCSI 0 DMA control (dir, flush, reset, irq)"),
 0x0014: ("HPC3_SCSI0_BCD",   "SCSI 0 byte count / descriptor"),
 0x0018: ("HPC3_SCSI0_PIOCFG","SCSI 0 PIO timing config"),
 0x1000: ("HPC3_SCSI1_DESC",  "SCSI channel 1 DMA descriptor"),
 0x1010: ("HPC3_SCSI1_CTRL",  "SCSI 1 DMA control"),
 0x1018: ("HPC3_SCSI1_PIOCFG","SCSI 1 PIO timing config"),
 0x2000: ("HPC3_ENET_RX_CBP", "SEEQ 8003 Ethernet RX current buffer pointer"),
 0x2004: ("HPC3_ENET_RX_NBDP","Ethernet RX next buffer descriptor"),
 0x2008: ("HPC3_ENET_RX_BC",  "Ethernet RX byte count"),
 0x200c: ("HPC3_ENET_RX_CTRL","Ethernet RX control/status"),
 0x2010: ("HPC3_ENET_RX_GIO", "Ethernet RX GIO FIFO"),
 0x2014: ("HPC3_ENET_RX_DEV", "Ethernet RX device FIFO"),
 0x2018: ("HPC3_ENET_RX_RESET","Ethernet RX reset"),
 0x201c: ("HPC3_ENET_DMACFG", "Ethernet DMA config"),
 0x2020: ("HPC3_ENET_PIOCFG", "Ethernet PIO config"),
 0x2100: ("HPC3_ENET_TX_CBP", "Ethernet TX current buffer pointer"),
 0x2104: ("HPC3_ENET_TX_NBDP","Ethernet TX next buffer descriptor"),
 0x2108: ("HPC3_ENET_TX_BC",  "Ethernet TX byte count"),
 0x210c: ("HPC3_ENET_TX_CTRL","Ethernet TX control/status"),
 0x4000: ("HPC3_PBUS_DMA",    "PBUS (parallel/audio/etc) DMA descriptors, 8 channels"),
 0x8000: ("HPC3_SCSI0_DEV",   "WD33C93B SCSI controller 0, device registers"),
 0x8800: ("HPC3_SCSI1_DEV",   "WD33C93B SCSI controller 1, device registers"),
 0x9000: ("HPC3_ENET_DEV",    "SEEQ 8003 Ethernet device registers"),
 0x9800: ("HPC3_BBRAM",       "Dallas DS1386 battery-backed RAM + RTC (byte-wide, stride 4)"),
 0xc000: ("HPC3_GENCTRL",     "HPC3 general control / misc"),
}

# Well-known absolute leaf addresses inside HPC3 space
# The SCSI descriptor table at 0xbfc7b410 (2 x 44-byte records) gives these
# exactly: WD33C93B address/data ports and the HPC3 DMA blocks per channel.
SCSI_ABS = {
 0x1fbc0003: "WD33C93B ch0: address/command port (byte in low 8 bits of word)",
 0x1fbc0007: "WD33C93B ch0: data port",
 0x1fbc8003: "WD33C93B ch1: address/command port",
 0x1fbc8007: "WD33C93B ch1: data port",
 0x1fb90000: "HPC3 ch0 DMA descriptor / CBP",
 0x1fb90004: "HPC3 ch0 DMA NBDP",
 0x1fb91000: "HPC3 ch0 DMA byte count",
 0x1fb91004: "HPC3 ch0 DMA control (0x40 = reset)",
 0x1fb91010: "HPC3 ch0 DMA PIO config / status",
 0x1fb91014: "HPC3 ch0 DMA PIO config 2",
 0x1fb92000: "HPC3 ch1 DMA descriptor / CBP",
 0x1fb92004: "HPC3 ch1 DMA NBDP",
 0x1fb93000: "HPC3 ch1 DMA byte count",
 0x1fb93004: "HPC3 ch1 DMA control (0x40 = reset)",
 0x1fb93010: "HPC3 ch1 DMA PIO config / status",
 0x1fb93014: "HPC3 ch1 DMA PIO config 2",
}

# HAL2 (Iris Audio Processor) - indirect register file, verified against the
# PROM's own access pattern in FUN_bfc00bd0.
HAL2_BASE = 0x1fbd8000
HAL2 = {
 0x10: ("HAL2_ISR",  "Interrupt/status; bit0 = indirect access busy (poll until 0)"),
 0x20: ("HAL2_REV",  "Revision; bit15 set = audio NOT present"),
 0x30: ("HAL2_IAR",  "Indirect address register (latches the access)"),
 0x40: ("HAL2_IDR0", "Indirect data 0"),
 0x50: ("HAL2_IDR1", "Indirect data 1"),
 0x60: ("HAL2_IDR2", "Indirect data 2"),
 0x70: ("HAL2_IDR3", "Indirect data 3"),
}
# Indirect addresses the PROM actually writes
HAL2_INDIRECT = {
 0x2104: "BRES2 clock select (1 = 44.1 kHz crystal family)",
 0x2108: "BRES2 Bresenham inc/mod (inc=1, mod=2 -> master/2 = 22050 Hz)",
 0x9100: "RELAY_C - speaker relay control",
 0x9104: "RELAY_C - speaker relay control (alternate access width)",
}

HPC3_ABS = {
 0x1fb80000: "HPC3_SCSI0 DMA descriptor block",
 0x1fb81000: "HPC3_SCSI1 DMA descriptor block",
 0x1fb82000: "HPC3 Ethernet DMA block",
 0x1fb90000: "HPC3 alias: SCSI0",
 0x1fb98000: "HPC3 alias: SCSI1",
 0x1fb9c000: "HPC3 alias: Ethernet",
 0x1fbb0000: "HPC3 misc / PBUS external regs",
 0x1fbc0000: "HPC3 PBUS device space",
 0x1fbd8000: "HAL2 audio (Indy) / PBUS device",
 0x1fbd9800: "HPC3 write / general control (misc regs, LED, EISA, ...)",
 0x1fbd9880: "HPC3 PBUS external device 0 (Zilog 85C30 DUART / keyboard)",
 0x1fbd9000: "SEEQ 8003 / WD33C93 device window",
 0x1fbe0000: "Dallas DS1286/DS1386 RTC + NVRAM (byte-wide, stride 4)",
}

# ---- INT2 local interrupt controller (inside HPC3 space) ----------------
INT2_BASE = 0x1fbd9880
INT2 = {
 0x00: ("INT2_LOCAL0_STAT", "Local 0 interrupt status (read-only)"),
 0x04: ("INT2_LOCAL0_MASK", "Local 0 interrupt mask"),
 0x08: ("INT2_LOCAL1_STAT", "Local 1 interrupt status (read-only)"),
 0x0c: ("INT2_LOCAL1_MASK", "Local 1 interrupt mask"),
 0x10: ("INT2_MAP0_ISR",    "Interrupt map 0 status"),
 0x14: ("INT2_MAP0_MASK",   "Interrupt map 0 mask"),
 0x18: ("INT2_MAP1_ISR",    "Interrupt map 1 status"),
 0x1c: ("INT2_MAP1_MASK",   "Interrupt map 1 mask"),
 0x20: ("INT2_VMEIRQ",      "VME/GIO interrupt"),
 0x30: ("INT2_TIMER_CLR",   "Timer interrupt clear"),
 0x34: ("INT2_ERRSTAT",     "Error status"),
 0x40: ("INT2_TCLK0",       "8254 timer counter 0"),
 0x44: ("INT2_TCLK1",       "8254 timer counter 1"),
 0x48: ("INT2_TCLK2",       "8254 timer counter 2"),
 0x4c: ("INT2_TCTRL",       "8254 timer control word"),
}

def lookup(addr):
    """Return (name, note) for a virtual address, or None."""
    return _lookup(addr)


def _lookup(addr):
    """Return (name, note) for a virtual address, or None."""
    a = addr
    if 0xa0000000 <= a < 0xc0000000: p = a & 0x1fffffff
    elif 0x80000000 <= a < 0xa0000000: p = a & 0x1fffffff
    else: p = a
    # Dallas DS1386-8K: one device byte per 32-bit word (stride 4, byte in the
    # low 8 bits). Device bytes 0x00-0x3f are the RTC/control file; the PROM's
    # "NVRAM offset 0" is device byte 0x40, i.e. phys 0x1fbe0100.
    if 0x1fbe0000 <= p < 0x1fbe8000:
        idx = (p - 0x1fbe0000) >> 2
        if idx < 0x40:
            return ("RTC_reg%02x" % idx,
                    "DS1386 RTC/control register %d (byte-wide, stride 4)" % idx)
        return ("NVRAM+0x%02x" % (idx - 0x40),
                "NVRAM byte %d (PROM offset 0 == device byte 0x40)" % (idx - 0x40))
    if p in SCSI_ABS:
        return ("SCSI_%08x" % p, SCSI_ABS[p])
    if HAL2_BASE <= p < HAL2_BASE + 0x80:
        off = p - HAL2_BASE
        if off in HAL2: return HAL2[off]
    if MC_BASE <= p < MC_BASE + 0x20000:
        off = p - MC_BASE
        for base in (off, off - 4):
            if base in MC:
                n, d = MC[base]
                return (n + ("+4(lo)" if base != off else ""), d)
        return ("MC+0x%04x" % off, "Memory controller (unnamed)")
    if INT2_BASE <= p < INT2_BASE + 0x60:
        off = p - INT2_BASE
        if off in INT2: return INT2[off]
        return ("INT2+0x%02x" % off, "INT2 interrupt controller (unnamed)")
    for abs_a, name in sorted(HPC3_ABS.items(), reverse=True):
        if abs_a <= p < abs_a + 0x100:
            return ("%s+0x%02x" % (name.split()[0], p - abs_a), name)
    if HPC3_BASE <= p < 0x1fc00000:
        off = p - HPC3_BASE
        for base in sorted(HPC3, reverse=True):
            if base <= off < base + 0x800:
                n, d = HPC3[base]
                return (n + ("+0x%x" % (off - base) if off != base else ""), d)
        return ("HPC3+0x%05x" % off, "HPC3 (unnamed)")
    for s, e, name, note in REGIONS:
        if s <= p < e:
            if name == "MAIN_MEMORY":
                return ("RAM+0x%x" % (p - s), note)
            return ("%s+0x%x" % (name, p - s), note)
    return None
