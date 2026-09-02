# Verilator harness for the SGI core.
#
# Cross-platform (macOS / Linux / MinGW) SDL2 + OpenGL2 + Dear ImGui, using the
# standard MiSTer verilator sim framework in sim/ (sim_bus, sim_console,
# sim_video, sim_input, sim_audio, sim_serial, sim_blkdevice, sim_clock).
#
# Build:  make            Run: ./obj_dir/Vemu
# macOS deps: brew install verilator sdl2

V     = verilator
TOP   = --top-module emu
RTL   = ../rtl
V_INC = +incdir+$(RTL)

V_DEFINE = +define+SIMULATION=1 \
	-CFLAGS "-I../sim/imgui -I../sim/vinc -I../sim/ -g" \
	--timescale-override 1ps/1ps -Wno-TIMESCALEMOD \
	-I$(RTL) -I$(RTL)/sgi -I$(RTL)/cpu -I$(RTL)/newport \
	--timing

# Warnings that don't affect simulation correctness in this style of RTL.
V_DEFINE += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-IMPLICIT -Wno-PINMISSING \
            -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-UNSIGNED \
            -Wno-CMPCONST -Wno-LATCH -Wno-UNDRIVEN -Wno-MISINDENT -Wno-COMBDLY \
            -Wno-INITIALDLY -Wno-SYNCASYNCNET -Wno-ALWNEVER -Wno-PROCASSWIRE \
            -Wno-BLKANDNBLK -Wno-MULTIDRIVEN
V_DEFINE += --trace-fst

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S), Darwin)
	LIBS += -framework OpenGL -framework Cocoa -framework IOKit -framework CoreVideo `sdl2-config --libs`
	LIBS += -L/usr/local/lib -L/opt/local/lib -L/opt/homebrew/lib
	CXXFLAGS += `sdl2-config --cflags` -Iimgui
	CXXFLAGS += `sdl2-config --cflags | sed 's|include/SDL2|include/|'`
	CXXFLAGS += -I/usr/local/include -I/opt/local/include -I/opt/homebrew/include
	CFLAGS = $(CXXFLAGS) -Iimgui
endif

ifeq ($(UNAME_S), Linux)
	LIBS += -lGL -ldl `sdl2-config --libs`
	CXXFLAGS += `sdl2-config --cflags` -Iimgui
	CFLAGS = $(CXXFLAGS)
endif

ifeq ($(findstring MINGW,$(UNAME_S)),MINGW)
	LIBS += -lgdi32 -lopengl32 -limm32 `pkg-config --static --libs sdl2`
	CXXFLAGS += `pkg-config --cflags sdl2`
	CFLAGS = $(CXXFLAGS)
endif

CFLAGS  += $(CC_OPT) $(CC_DEFINE) -Iimgui
LDFLAGS  = $(LIBS)
EXE      = ./obj_dir/Vemu
V_OPT    = --x-assign fast --x-initial fast --noassert

# --- RTL under test -------------------------------------------------------
# sim.v is the simulation wrapper (module `emu`) that instantiates the core the
# same way sgiindy.sv does on hardware, but with sim_ram.v in place of SDRAM
# and the PROM fed from the C++ side.
V_SRC = \
	sim.v \
	sim_ram.v \
	$(RTL)/sgi/sgi_mc.v \
	$(RTL)/sgi/z8530_scc.sv
#	$(RTL)/cpu/aoR3000.v          <- add once the CPU is wired in
#	$(RTL)/sgi/sgi_int2.sv
#	$(RTL)/sgi/sgi_ds1386.sv
#	$(RTL)/sgi/sgi_hpc3.sv

C_SRC = \
	sim_main.cpp \
	sim/sim_bus.cpp sim/sim_blkdevice.cpp sim/sim_clock.cpp sim/sim_console.cpp \
	sim/sim_video.cpp sim/sim_input.cpp sim/sim_audio.cpp sim/sim_serial.cpp \
	sim/imgui/imgui_impl_sdl.cpp sim/imgui/imgui_impl_opengl2.cpp sim/imgui/imgui_draw.cpp \
	sim/imgui/imgui_widgets.cpp sim/imgui/imgui_tables.cpp sim/imgui/imgui.cpp \
	sim/imgui/ImGuiFileDialog.cpp sim/imgui/implot.cpp sim/imgui/implot_items.cpp

VOUT = obj_dir/Vemu.cpp

all: $(EXE)

$(VOUT): $(V_SRC) Makefile
	$V -cc $(V_OPT) -LDFLAGS "$(LDFLAGS) " -exe --trace --Mdir ./obj_dir \
	   $(V_DEFINE) $(V_INC) $(TOP) -CFLAGS $(CFLAGS) $(V_SRC) $(C_SRC)

$(EXE): $(VOUT) $(C_SRC)
	(cd obj_dir; make -f Vemu.mk)

clean:
	rm -rf obj_dir

# --- headless CPU-validation harness --------------------------------------
# No SDL, no ImGui, no window: this is the target CI and bisection use.
#   make cputest
#   ./obj_dir/Vsim_top --elf .../cputest.elf --testdev
CPUTEST_V = \
	sim_top.sv \
	sim_ram.v \
	$(RTL)/sgi/sgi_indy.sv \
	$(RTL)/sgi/sgi_mc.sv \
	$(RTL)/sgi/mc_gio_dma.sv \
	$(RTL)/sgi/sgi_hpc3.sv \
	$(RTL)/sgi/hal2.sv \
	$(RTL)/sgi/hpc3_scsi_dma.sv \
	$(RTL)/sgi/sgi_ioc.sv \
	$(RTL)/sgi/i8042.sv \
	$(RTL)/scsi/sgi_scsi.sv \
	$(RTL)/scsi/wd33c93.sv \
	$(RTL)/scsi/scsi.v \
	$(RTL)/scsi/cd_audio.sv \
	$(RTL)/sgi/pit8254.sv \
	$(RTL)/sgi/ram_arb.sv \
	$(RTL)/sgi/sgi_memmap.sv \
	$(RTL)/sgi/sgi_ds1386.sv \
	$(RTL)/sgi/eeprom_93c56.sv \
	$(RTL)/sgi/sgi_scc.sv \
	$(RTL)/sgi/z8530_scc.sv \
	$(RTL)/newport/newport.sv \
	$(RTL)/newport/np_rex3.sv \
	$(RTL)/newport/np_vc2.sv \
	$(RTL)/newport/np_xmap9.sv \
	$(RTL)/newport/np_cmap.sv \
	$(RTL)/newport/np_bt445.sv \
	$(RTL)/cpu/r4300_bus.sv \
	$(RTL)/cpu/generated/r4300_wrap.v

CPUTEST_C = sim_cputest.cpp sim_devices.cpp

CPUTEST_W = +incdir+$(RTL)/scsi -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
            -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-DECLFILENAME \
            -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN -Wno-SYNCASYNCNET

$(RTL)/cpu/generated/r4300_wrap.v:
	../tools/gen_r4300_verilog.sh

cputest: $(RTL)/cpu/generated/r4300_wrap.v
	$V -cc --exe --build -j 0 --Mdir ./obj_dir --top-module sim_top \
	   -O3 -CFLAGS "-O2 -std=c++17 -I.." $(CPUTEST_W) \
	   --x-assign fast --x-initial fast --noassert \
	   -o Vsim_top $(CPUTEST_V) $(CPUTEST_C)


# --- whole-machine headless harness (builds on Verilator 5.020) ------------
# The same sim_top as `cputest`, but with the three flags that Verilator 5.020
# needs to get through this design. Each was found by building it, not guessed:
#   -fno-gate          V3Gate.cpp:693 "No pending substitutions" on scsi.v
#   -O0                every level above it dies in a later pass with an
#                      internal fault that prints no location (np_rex3.sv)
#   --unroll-count     sgi_hpc3.sv:339 resets a 128-entry array in a for loop,
#                      which is BLKLOOPINIT unless the loop is unrolled
# plus -Wno-MULTIDRIVEN for the dual-port RAM in the generated CPU.
# NOTE: rtl/cpu/generated/r4300_wrap.v must be current - a stale one is missing
# the nine dbg_* ports sgi_indy.sv connects and fails with PINNOTFOUND.
#   make -C verilator wholemachine
#   ./obj_wm/Vsim_top --prom ../boot.rom --no-gfx --disk 1=disk.img
WM_W = $(CPUTEST_W) -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKANDNBLK
WM_OPT = -fno-gate -O0 --unroll-count 2048 --unroll-stmts 20000 	 -finline -flife -flife-post -fconst -fsubst -fsubst-const 	 -fassemble -fcombine -fexpand -fcase -fdedup -freorder -fsplit 	 -fmerge-cond -ftable

# Extra plusargs for either whole-machine target, so a `+define+` does not
# need the command line spelled out by hand:
#   make wholemachine2 WM_DEFS=+define+MSG_DEBUG
# turns on scsi.v's per-message $display, which is the only way to see the
# bytes IRIX actually puts in a MESSAGE OUT - IRIS cannot show them, its model
# reads them directly rather than through DMA.
WM_DEFS =

# A SECOND BUILD DIRECTORY, and it earns its keep. Overwriting a running
# executable fails with ETXTBSY, so an instrumentation change cannot be
# compiled while a 28-minute boot is still running out of ./obj_wm - and
# serialising the two costs half an hour every time. Identical in every other
# respect; ./obj_wm2/Vsim_top takes the same switches.
wholemachine2: $(RTL)/cpu/generated/r4300_wrap.v
	$V -cc --exe --build -j 0 --Mdir ./obj_wm2 --top-module sim_top 	   $(WM_DEFS) $(WM_OPT) -CFLAGS "-O2 -std=c++17 -I$(CURDIR)/.." $(WM_W) 	   --x-assign fast --x-initial fast --noassert 	   -o Vsim_top $(CPUTEST_V) $(CURDIR)/sim_cputest.cpp $(CURDIR)/sim_devices.cpp

wholemachine: $(RTL)/cpu/generated/r4300_wrap.v
	$V -cc --exe --build -j 0 --Mdir ./obj_wm --top-module sim_top 	   $(WM_OPT) -CFLAGS "-O2 -std=c++17 -I$(CURDIR)/.." $(WM_W) 	   --x-assign fast --x-initial fast --noassert 	   -o Vsim_top $(CPUTEST_V) $(CURDIR)/sim_cputest.cpp $(CURDIR)/sim_devices.cpp

# --- interactive harness ---------------------------------------------------
# Same sim_top, same C++ device models as `cputest`, plus SDL2 + OpenGL2 +
# Dear ImGui from the vendored MiSTer sim framework.
#   make gui && ./obj_dir/Vsim_gui --prom ../roms/IP24_Indy/ip24prom....bin --run
GUI_C = sim_gui.cpp sim_devices.cpp \
	sim/imgui/imgui_impl_sdl.cpp sim/imgui/imgui_impl_opengl2.cpp \
	sim/imgui/imgui_draw.cpp sim/imgui/imgui_widgets.cpp \
	sim/imgui/imgui_tables.cpp sim/imgui/imgui.cpp

# Paths are relative to obj_dir_gui/, where verilator runs the compile.
GUI_CFLAGS = -O2 -std=c++17 -I.. -I../.. -I../sim/imgui $(shell sdl2-config --cflags)
GUI_LDFLAGS = $(shell sdl2-config --libs)
ifeq ($(UNAME_S), Darwin)
	GUI_LDFLAGS += -framework OpenGL
else
	GUI_LDFLAGS += -lGL
endif

gui: $(RTL)/cpu/generated/r4300_wrap.v
	$V -cc --exe --build -j 0 --Mdir ./obj_dir_gui --top-module sim_top \
	   -O3 -CFLAGS "$(GUI_CFLAGS)" -LDFLAGS "$(GUI_LDFLAGS)" $(CPUTEST_W) \
	   --x-assign fast --x-initial fast --noassert \
	   -o ../obj_dir/Vsim_gui $(CPUTEST_V) $(GUI_C)

# --- CPU-only harness -----------------------------------------------------
# The CPU, r4300_bus and a memory whose latency is a runtime input. Nothing
# else - and that is the point twice over. It builds where `cputest` does not,
# because `rtl/scsi/scsi.v` is what Verilator 5.020 dies on (V3Gate.cpp:693),
# so a machine with only that Verilator can still answer CPU questions. And a
# settable memory latency is the only way to chase a fault that appears on
# about one hardware boot in three: on the board, DDR3 refresh, the HPS's own
# traffic and Newport's frame buffer reads move the answer time around, and
# nothing in a fixed-latency simulation ever sees the bad one.
#   make -C verilator cpuonly && ./obj_dir_cpuonly/Vtb_cpuonly
CPUONLY_V = tb_cpuonly.sv $(RTL)/cpu/r4300_bus.sv $(RTL)/cpu/generated/r4300_wrap.v

# -Wno-PINMISSING: this bench predates the nine dbg_* observability pins on
# r4300_wrap and deliberately leaves them open - it watches the CPU through the
# bus, not through the taps. Without it the build stops on nine warnings-as-
# errors and the bench looks broken when it is only uninterested.
cpuonly: $(RTL)/cpu/generated/r4300_wrap.v
	$V -cc --exe --build -j 0 --Mdir ./obj_dir_cpuonly --top-module tb_cpuonly -Wno-PINMISSING 	   -O3 -CFLAGS "-O2 -std=c++17" $(CPUTEST_W) 	   --x-assign fast --x-initial fast --noassert 	   -o Vtb_cpuonly $(CPUONLY_V) tb_cpuonly.cpp
	./obj_dir_cpuonly/Vtb_cpuonly

# --- HAL2 register file unit test ------------------------------------------
# The audio processor's IAR/IDR indirect file, checked against IRIS's decode.
# One check in it is a boot-stopper rather than an audio bug: ISR bit 0 is what
# the PROM's audio init spins on and it has to stay clear.
#   make -C verilator hal2test
hal2test:
	$V -cc --exe --build -j 0 --Mdir ./obj_dir_hal2 --top-module hal2 	   -O3 -CFLAGS "-O2 -std=c++17" $(CPUTEST_W) 	   --x-assign fast --x-initial fast --noassert 	   -o Vhal2 $(RTL)/sgi/hal2.sv tb_hal2.cpp
	./obj_dir_hal2/Vhal2

# --- MC GIO64 DMA fill engine unit test ------------------------------------
# Checks the engine against a C++ transcription of IRIS's own dma_worker loop,
# at two arbiter ack delays. It is a module test rather than part of cputest
# because the full design will not build under Verilator 5.020, and this engine
# is the one that decides whether a boot starts on cleared memory.
#   make -C verilator mcdmatest
mcdmatest:
	$V -cc --exe --build -j 0 --Mdir ./obj_dir_mcdma --top-module mc_gio_dma 	   -O3 -CFLAGS "-O2 -std=c++17" $(CPUTEST_W) 	   --x-assign fast --x-initial fast --noassert 	   -o Vmc_gio_dma $(RTL)/sgi/mc_gio_dma.sv tb_mcdma.cpp
	./obj_dir_mcdma/Vmc_gio_dma

# --- VC2 video timing generator unit test ---------------------------------
# The timing generator is an interpreter for a table in VC2's external SRAM.
# This drives it directly with a table of a known geometry, so a wrong picture
# in a boot can be attributed to the walk or ruled out of it.
#   make vc2test && ./obj_dir_vc2/Vnp_vc2
vc2test:
	$V -cc --exe --build -j 0 --Mdir ./obj_dir_vc2 --top-module np_vc2 \
	   -O3 -CFLAGS "-O2 -std=c++17 -I.." $(CPUTEST_W) \
	   --x-assign fast --x-initial fast --noassert \
	   -o Vnp_vc2 $(RTL)/newport/np_vc2.sv tb_vc2.cpp

# --- the same harness with REX3's per-command trace ------------------------
# np_rex3.sv's `ifdef REX3_DEBUG block prints one line per accepted GO: the
# drawmode words, the two corners, the octant, the z-pattern and the colour.
# A wrong picture is nearly always a command the engine was given rather than
# one it mishandled, and ng1_tp.c is right there to compare against.
#   make cputest-rex3-debug && ./obj_dir_rex3dbg/Vsim_top --prom ... 2>&1 | less
# WM_OPT rather than -O3: every optimisation level above -O0 dies in a
# Verilator 5.020 internal fault just after np_rex3.sv (the same fault the
# wholemachine targets work around), and this target elaborates the same
# whole design. See the WM_OPT comment above.
cputest-rex3-debug: $(RTL)/cpu/generated/r4300_wrap.v
	$V -cc --exe --build -j 0 --Mdir ./obj_dir_rex3dbg --top-module sim_top \
	   $(WM_OPT) -CFLAGS "-O2 -std=c++17 -I.." $(WM_W) +define+REX3_DEBUG \
	   --x-assign fast --x-initial fast --noassert \
	   -o Vsim_top $(CPUTEST_V) $(CPUTEST_C)

# --- the same harness with the Display Control Bus traced -----------------
# np_rex3.sv and np_cmap.sv's `ifdef DCB_DEBUG blocks print one line per DCB
# transfer - chip address, register select, width, swap and the whole 32-bit
# datum - and one per byte the colour map receives. Everything on the Newport
# board except REX3 is reached through that bus, so when a palette, a mode
# table or a timing table is wrong this is the only place the wrongness is
# visible: the transfer either carried the byte or it did not.
#   make cputest-dcb-debug && ./obj_dir_dcbdbg/Vsim_top --prom ... 2>&1 | less
cputest-dcb-debug: $(RTL)/cpu/generated/r4300_wrap.v
	$V -cc --exe --build -j 0 --Mdir ./obj_dir_dcbdbg --top-module sim_top \
	   -O3 -CFLAGS "-O2 -std=c++17 -I.." $(CPUTEST_W) +define+DCB_DEBUG \
	   --x-assign fast --x-initial fast --noassert \
	   -o Vsim_top $(CPUTEST_V) $(CPUTEST_C)

# --- DDR3 mux unit test ----------------------------------------------------
# The MiSTer memory path is the one part of the top level that has behaviour
# rather than wiring, and no Quartus is needed to check it. The bridge model in
# tb_ddr3.cpp is deliberately unhelpful - random BUSY, random read latency,
# garbage on DOUT except on the ready cycle - because a mux that passes against
# a bridge that is never busy is a mux that has not been tested.
#   make ddr3test && ./obj_dir_ddr3/Vddr3_mux
# --- the CPU/DMA memory arbiter against a SLOW memory ----------------------
# The one piece of this design that could not be tested until it was its own
# file. Every whole-machine simulation here answers memory in one cycle, and
# the fault it hid opens a window as wide as memory is slow. See the header
# of verilator/tb_ramarb.cpp and of rtl/sgi/ram_arb.sv.
#   make ramarbtest && ./obj_dir_ramarb/Vram_arb
#   RAMARB_LAT=60 ./obj_dir_ramarb/Vram_arb    # DDR3-ish
#   RAMARB_LAT=1  ./obj_dir_ramarb/Vram_arb    # what sim_ram.v offers
ramarbtest:
	$V -cc --exe --build -j 0 --Mdir ./obj_dir_ramarb --top-module ram_arb \
	   -O3 -CFLAGS "-O2 -std=c++17 -I.." $(CPUTEST_W) \
	   --x-assign fast --x-initial fast --noassert \
	   -o Vram_arb $(RTL)/sgi/ram_arb.sv tb_ramarb.cpp

ddr3test:
	$V -cc --exe --build -j 0 --Mdir ./obj_dir_ddr3 --top-module ddr3_mux \
	   -O3 -CFLAGS "-O2 -std=c++17 -I.." $(CPUTEST_W) \
	   --x-assign fast --x-initial fast --noassert \
	   -o Vddr3_mux $(RTL)/mister/ddr3_mux.sv tb_ddr3.cpp

# --- frame buffer line cache unit test -------------------------------------
# Driven with the display's REAL access pattern - n1280_r3's 1318 of 1680
# pixels and 1024 of 1065 lines, blanking included - against a memory that
# accepts a burst late and returns it in gaps. A cache tested with random
# addresses would be a different cache.
#   make linecachetest && ./obj_dir_lcache/Vfb_linecache
linecachetest:
	$V -cc --exe --build -j 0 --Mdir ./obj_dir_lcache --top-module fb_linecache \
	   -O3 -CFLAGS "-O2 -std=c++17 -I.." $(CPUTEST_W) \
	   --x-assign fast --x-initial fast --noassert \
	   -o Vfb_linecache $(RTL)/mister/fb_linecache.sv tb_linecache.cpp

# --- the rasteriser against a memory that is not always ready ---------------
# tests/run-rex3.sh is the strong test of WHAT REX3 draws - every command
# replayed against every pixel - but it runs on sim_top, whose memory accepts a
# request every single cycle and never refuses one. rtl/mister/ddr3_mux.sv
# refuses constantly: it holds one transaction at a time and takes tens of
# cycles over it. This drives np_rex3 on its own against that contract and
# checks that a filled rectangle actually reaches memory.
#   make rex3test && ./obj_dir_rex3/Vnp_rex3
#   REX3_ACK_DELAY=40 ./obj_dir_rex3/Vnp_rex3     # DDR3-ish
#   REX3_ACK_DELAY=0  ./obj_dir_rex3/Vnp_rex3     # the memory sim_top has
#   REX3_MAP=1        ./obj_dir_rex3/Vnp_rex3     # print the coverage map
rex3test:
	$V -cc --exe --build -j 0 --Mdir ./obj_dir_rex3 --top-module np_rex3 	   -O3 -CFLAGS "-O2 -std=c++17 -I.." $(CPUTEST_W) 	   --x-assign fast --x-initial fast --noassert 	   -o Vnp_rex3 $(RTL)/newport/np_rex3.sv tb_rex3.cpp

.PHONY: cputest gui vc2test cputest-rex3-debug cputest-dcb-debug ddr3test linecachetest rex3test all clean

# --- the same harness with the DMA engine's per-cycle state trace ----------
# hpc3_scsi_dma.sv's `ifdef DMA_DEBUG block is silent and free in the normal
# build; this target turns it on into its own obj_dir so the ratchets keep
# running against the quiet binary. One line per cycle - redirect it.
#   make cputest-dma-debug && ./obj_dir_dmadbg/Vsim_top --elf ... 2>&1 | less
cputest-dma-debug: $(RTL)/cpu/generated/r4300_wrap.v
	$V -cc --exe --build -j 0 --Mdir ./obj_dir_dmadbg --top-module sim_top \
	   -O3 -CFLAGS "-O2 -std=c++17 -I.." $(CPUTEST_W) +define+DMA_DEBUG \
	   --x-assign fast --x-initial fast --noassert \
	   -o Vsim_top $(CPUTEST_V) $(CPUTEST_C)
