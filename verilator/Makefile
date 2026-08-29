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
	$(RTL)/sgi/sgi_hpc3.sv \
	$(RTL)/sgi/hpc3_scsi_dma.sv \
	$(RTL)/sgi/sgi_ioc.sv \
	$(RTL)/sgi/i8042.sv \
	$(RTL)/scsi/sgi_scsi.sv \
	$(RTL)/scsi/wd33c93.sv \
	$(RTL)/scsi/scsi.v \
	$(RTL)/scsi/cd_audio.sv \
	$(RTL)/sgi/pit8254.sv \
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
cputest-rex3-debug: $(RTL)/cpu/generated/r4300_wrap.v
	$V -cc --exe --build -j 0 --Mdir ./obj_dir_rex3dbg --top-module sim_top \
	   -O3 -CFLAGS "-O2 -std=c++17 -I.." $(CPUTEST_W) +define+REX3_DEBUG \
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

.PHONY: cputest gui vc2test cputest-rex3-debug cputest-dcb-debug all clean

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
