# scsiwr - build the SCSI DATA OUT image.
#
# start.S and link.ld are shared with tests/dma rather than copied: neither has
# anything to do with SCSI, and two copies of a linker script drift.
CROSS  ?= mipsel-linux-gnu-
CC     := $(CROSS)gcc
LD     := $(CROSS)ld
OBJDUMP:= $(CROSS)objdump

SHARED := ../dma

ARCH   := -march=mips3 -mabi=n32 -EB -mno-abicalls -fno-pic -G0 -msoft-float
CFLAGS := $(ARCH) -ffreestanding -nostdlib -nostdinc -fno-builtin \
          -fomit-frame-pointer -O1 -g -std=gnu11 -Wall -Wextra -Werror
LDFLAGS:= -EB -T $(SHARED)/link.ld -nostdlib --no-warn-mismatch

all: build/scsiwr.elf

build/scsiwr.elf: scsiwr.c $(SHARED)/start.S $(SHARED)/link.ld
	@mkdir -p build
	$(CC) $(CFLAGS) -c -o build/scsiwr.o scsiwr.c
	$(CC) $(ARCH) -ffreestanding -nostdlib -c -o build/start.o $(SHARED)/start.S
	$(LD) $(LDFLAGS) -o $@ build/scsiwr.o build/start.o
	@$(OBJDUMP) -h $@ | head -8

dis: build/scsiwr.elf
	$(OBJDUMP) -d $<

clean:
	rm -rf build
