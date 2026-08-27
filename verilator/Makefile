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
	-I$(RTL) -I$(RTL)/sgi -I$(RTL)/cpu \
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
	$(RTL)/sgi/sgi_scc.sv \
	$(RTL)/sgi/z8530_scc.sv \
	$(RTL)/cpu/r4300_bus.sv \
	$(RTL)/cpu/generated/r4300_wrap.v

CPUTEST_C = sim_cputest.cpp sim_devices.cpp

CPUTEST_W = -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
            -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-DECLFILENAME \
            -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN -Wno-SYNCASYNCNET

$(RTL)/cpu/generated/r4300_wrap.v:
	../tools/gen_r4300_verilog.sh

cputest: $(RTL)/cpu/generated/r4300_wrap.v
	$V -cc --exe --build -j 0 --Mdir ./obj_dir --top-module sim_top \
	   -O3 -CFLAGS "-O2 -std=c++17 -I.." $(CPUTEST_W) \
	   --x-assign fast --x-initial fast --noassert \
	   -o Vsim_top $(CPUTEST_V) $(CPUTEST_C)

.PHONY: cputest all clean
