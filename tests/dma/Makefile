# dmatest - build the INT2 interrupt-path image.
#
# Same toolchain and flags as the cpu-tests suite; see tests/README.md for
# where to get a MIPS cross compiler on macOS.
CROSS  ?= mipsel-linux-gnu-
CC     := $(CROSS)gcc
LD     := $(CROSS)ld
OBJDUMP:= $(CROSS)objdump

ARCH   := -march=mips3 -mabi=n32 -EB -mno-abicalls -fno-pic -G0 -msoft-float
CFLAGS := $(ARCH) -ffreestanding -nostdlib -nostdinc -fno-builtin \
          -fomit-frame-pointer -O1 -g -std=gnu11 -Wall -Wextra -Werror
LDFLAGS:= -EB -T link.ld -nostdlib --no-warn-mismatch

all: build/dmatest.elf

build/dmatest.elf: dmatest.c start.S link.ld
	@mkdir -p build
	$(CC) $(CFLAGS) -c -o build/dmatest.o dmatest.c
	$(CC) $(ARCH) -ffreestanding -nostdlib -c -o build/start.o start.S
	$(LD) $(LDFLAGS) -o $@ build/dmatest.o build/start.o
	@$(OBJDUMP) -h $@ | head -8

dis: build/dmatest.elf
	$(OBJDUMP) -d $<

clean:
	rm -rf build
