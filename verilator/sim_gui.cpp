//============================================================================
//  sim_gui - interactive Verilator harness: SDL2 + OpenGL2 + Dear ImGui.
//
//  Drives the SAME sim_top and the SAME C++ device models as the headless
//  sim_cputest harness. That is deliberate: a GUI that wrapped a different top
//  level would drift, and then "it works in the GUI" would stop meaning
//  anything about what CI runs.
//
//  It is a port of the DE1 sandbox's ImGui harness, which was Win32 + DirectX
//  11 and so could not be lifted across; the panels and the reasons for them
//  are the same, the platform layer is the MiSTer sim framework's SDL2 +
//  OpenGL2 backend that this repository already vendors.
//
//  Panels:
//    Control        run / stop / step / reset, cycle rate, cpu_error flags
//    Console        what the machine printed, and a box to type back at it
//    Bus trace      a rolling window with decoded register names
//    Holes          unclaimed addresses - the live map of what is missing
//    Hot            what the CPU is hammering, which is what a hang looks like
//    Memory         RAM and PROM hex editors
//    PROM patches   runtime word patches, for "what if this returned X"
//
//  TYPING AT THE MACHINE. The console input is a real UART transmitter on
//  rxdb, not a back door into the SCC's FIFO, so the receiver, the baud rate
//  generator and the RX FIFO all have to work for a keystroke to arrive. The
//  bit time is not configured: it is measured from the machine's own
//  transmitter (see UartRx below), so whatever the PROM programs into WR12/13
//  is automatically what the harness sends at.
//============================================================================

#include "Vsim_top.h"
#include "verilated.h"
#include "sim_devices.h"
#include "sim_uart.h"

#include <SDL.h>
#include <SDL_opengl.h>
#include "imgui.h"
#include "imgui_impl_sdl.h"
#include "imgui_impl_opengl2.h"
#include "imgui_memory_editor.h"

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <map>
#include <deque>
#include <algorithm>

using namespace sgisim;

static const uint64_t SCLK_DIV = 4;

// ---- MMIO names, same table as the headless harness ----------------------
struct RegName { uint32_t lo, hi; const char *name; };
static const RegName kRegNames[] = {
    { 0x08000000, 0x0FFFFFFF, "RAM"            },
    { 0x00000000, 0x0007FFFF, "RAM-alias"      },
    { 0x1F000000, 0x1F0EFFFF, "GFX-low"        },
    { 0x1F0F0000, 0x1F0FFFFF, "NEWPORT-REX3"   },
    { 0x1F400000, 0x1F5FFFFF, "GIO0"           },
    { 0x1FA00000, 0x1FA000FF, "MC"             },
    { 0x1FA00100, 0x1FA00FFF, "MC-lock"        },
    { 0x1FA01000, 0x1FA01FFF, "MC-RPSS_CTR"    },
    { 0x1FA02000, 0x1FA02FFF, "MC-GIO-DMA"     },
    { 0x1FA10000, 0x1FA1FFFF, "MC-semaphore"   },
    { 0x1FB80000, 0x1FB8FFFF, "HPC3-PBUS-DMA"  },
    { 0x1FB90000, 0x1FB93FFF, "HPC3-SCSI-DMA"  },
    { 0x1FB94000, 0x1FB97FFF, "HPC3-ENET-DMA"  },
    { 0x1FB98000, 0x1FB9FFFF, "HPC3-ENET-BDP"  },
    { 0x1FBB0000, 0x1FBB00FF, "HPC3-MISC"      },
    { 0x1FBC0000, 0x1FBCFFFF, "WD33C93-SCSI"   },
    { 0x1FBD4000, 0x1FBD4FFF, "SEEQ-ENET"      },
    { 0x1FBD8000, 0x1FBD83FF, "HAL2"           },
    { 0x1FBD8400, 0x1FBD87FF, "HPC3-PBUS-PIO1" },
    { 0x1FBD9000, 0x1FBD97FF, "HPC3-PBUS-PIO"  },
    { 0x1FBD9800, 0x1FBD982F, "IOC"            },
    { 0x1FBD9830, 0x1FBD9833, "SCC1_CMD"       },
    { 0x1FBD9834, 0x1FBD9837, "SCC1_DATA"      },
    { 0x1FBD9838, 0x1FBD983B, "SCC2_CMD"       },
    { 0x1FBD983C, 0x1FBD983F, "SCC2_DATA"      },
    { 0x1FBD9840, 0x1FBD987F, "IOC"            },
    { 0x1FBD9880, 0x1FBD98FF, "INT2"           },
    { 0x1FBD9900, 0x1FBD9FFF, "HPC3-EXT-IO"    },
    { 0x1FBDC000, 0x1FBDCFFF, "HPC3-CFG-DMA"   },
    { 0x1FBDD000, 0x1FBDDFFF, "HPC3-CFG-PIO"   },
    { 0x1FBE0000, 0x1FBE00FF, "DS1386-RTC"     },
    { 0x1FBE0100, 0x1FBE7FFF, "DS1386-NVRAM"   },
    { 0x1FBE8000, 0x1FBFFFFF, "HPC3"           },
    { 0x1FC00000, 0x1FC7FFFF, "PROM"           },
};

// Overlap, not containment: bus cycles are doubleword aligned even for a byte
// access, so a containment test silently never fires for a byte poll.
static const char *reg_name(uint32_t addr)
{
    uint32_t lo = addr, hi = addr + 7;
    for (const RegName &r : kRegNames)
        if (lo <= r.hi && hi >= r.lo) return r.name;
    return "?";
}

static const char *const kErrorNames[6] = {
    "instr(unimpl-cache-op)", "stall(pipeline-wedged)", "FPU-exception",
    "CPU-exception", "fifo-overflow", "TLB-busy"
};

// ---- one traced bus transaction ------------------------------------------
struct Txn {
    uint64_t cycle;
    uint32_t addr;
    uint64_t data;
    uint8_t  be;
    bool     we;
};

struct Hole { uint64_t count = 0, first = 0, last = 0; bool r = false, w = false; };

// A PROM word patch. The sandbox kept a list of these ("NOP the call at
// 0x1FC00560") as a map of where it had got stuck; they are answers to "would
// it get further if this went away", not fixes, so they live in the harness
// and never in the image on disk.
struct Patch { uint32_t addr; uint32_t value; bool enabled; char note[48]; };

static void usage()
{
    fprintf(stderr,
        "usage: Vsim_gui [options]\n"
        "  --prom FILE       load a boot PROM image at 0x1FC00000\n"
        "  --elf FILE        load a bare-metal ELF and boot from its entry point\n"
        "  --boot-pc HEX     override the reset PC (default 0xBFC00000)\n"
        "  --testdev         fit the IRIS test device in GIO64 slot 0\n"
        "  --ram-mb N        main memory size (default 64)\n"
        "  --run             start running immediately\n");
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);

    std::string prom_path, elf_path;
    uint32_t boot_pc = 0xBFC00000, ram_mb = 64;
    bool testdev = false, start_running = false;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&](const char *w) -> const char * {
            if (i + 1 >= argc) { fprintf(stderr, "%s needs a value\n", w); exit(2); }
            return argv[++i];
        };
        if      (a == "--prom")    prom_path = next("--prom");
        else if (a == "--elf")     elf_path  = next("--elf");
        else if (a == "--boot-pc") boot_pc   = strtoul(next("--boot-pc"), nullptr, 0);
        else if (a == "--testdev") testdev   = true;
        else if (a == "--run")     start_running = true;
        else if (a == "--ram-mb")  ram_mb    = strtoul(next("--ram-mb"), nullptr, 0);
        else if (a == "-h" || a == "--help") { usage(); return 0; }
        else if (a.rfind("+", 0) == 0 || a.rfind("-V", 0) == 0) { }
        else { fprintf(stderr, "unknown option %s\n", a.c_str()); usage(); return 2; }
    }

    g_dev.ram.resize((size_t)ram_mb * 1024 * 1024);
    g_dev.prom.resize(512 * 1024);
    g_dev.testdev.present = testdev;

    std::string load_msg;
    if (!prom_path.empty()) {
        FILE *f = fopen(prom_path.c_str(), "rb");
        if (!f) { fprintf(stderr, "cannot open PROM %s\n", prom_path.c_str()); return 2; }
        size_t n = fread(g_dev.prom.bytes.data(), 1, g_dev.prom.bytes.size(), f);
        fclose(f);
        load_msg = "PROM " + prom_path + " (" + std::to_string(n) + " bytes)";
    }
    if (!elf_path.empty()) {
        ElfLoadResult r = load_elf(elf_path);
        if (!r.ok) { fprintf(stderr, "ELF load failed: %s\n", r.error.c_str()); return 2; }
        if (boot_pc == 0xBFC00000) boot_pc = r.entry;
        load_msg = "ELF " + elf_path + " entry " + std::to_string(r.entry);
    }

    // ---- SDL / GL / ImGui ------------------------------------------------
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);
    SDL_Window *window = SDL_CreateWindow(
        "SGI Indy (IP24) - Verilator", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        1500, 950, SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
    SDL_GLContext gl = SDL_GL_CreateContext(window);
    SDL_GL_MakeCurrent(window, gl);
    SDL_GL_SetSwapInterval(1);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::StyleColorsDark();
    ImGui_ImplSDL2_InitForOpenGL(window, gl);
    ImGui_ImplOpenGL2_Init();

    // ---- the model -------------------------------------------------------
    Vsim_top *top = new Vsim_top;
    top->reset = 1; top->sclk = 0; top->clk = 0;
    top->boot_pc = boot_pc;
    top->gio_present = testdev ? 1 : 0;
    top->rxdb = 1;

    uint64_t cycle = 0;
    bool     running = start_running;
    int      step_batch = 200000;          // cycles per rendered frame
    bool     step_once = false, step_many = false;

    std::string console;
    std::deque<Txn> trace;
    size_t   trace_cap = 4000;
    bool     trace_on = true;
    std::map<uint32_t, uint64_t> hot;
    std::map<uint32_t, Hole> holes;
    uint64_t err_count[6] = {0};
    uint8_t  err_prev = 0;
    size_t   td_seen = 0;
    UartRx   urx;
    UartTx   utx;
    uint64_t last_cycle_mark = 0;
    double   cycles_per_sec = 0;
    uint32_t last_rate_ms = SDL_GetTicks();
    char     type_buf[256] = {0};

    std::vector<Patch> patches;
    auto apply_patch = [&](const Patch &p) {
        if (p.addr < 0x1FC00000 || p.addr + 3 >= 0x1FC00000 + g_dev.prom.size()) return;
        size_t o = p.addr - 0x1FC00000;
        g_dev.prom.bytes[o+0] = (p.value >> 24) & 0xFF;
        g_dev.prom.bytes[o+1] = (p.value >> 16) & 0xFF;
        g_dev.prom.bytes[o+2] = (p.value >>  8) & 0xFF;
        g_dev.prom.bytes[o+3] = (p.value      ) & 0xFF;
    };

    MemoryEditor ram_edit, prom_edit;

    auto step_cycle = [&]() {
        if (cycle == 8) top->reset = 0;

        top->clk = 1; top->eval();
        if ((cycle & (SCLK_DIV - 1)) == 0) top->sclk = !top->sclk;

        urx.sample(cycle, top->txdb);
        utx.step(cycle, urx.bit_time);
        top->rxdb = utx.line;

        if (top->tx_valid) console.push_back((char)top->tx_data);

        if (top->bus_ack) {
            hot[top->bus_addr]++;
            if (trace_on) {
                trace.push_back({cycle, top->bus_addr,
                                 top->bus_we ? top->bus_wdata : top->bus_rdata,
                                 (uint8_t)top->bus_be, (bool)top->bus_we});
                while (trace.size() > trace_cap) trace.pop_front();
            }
        }
        if (top->bus_unclaimed) {
            Hole &h = holes[top->bus_addr];
            if (!h.count) h.first = cycle;
            h.last = cycle; h.count++;
            if (top->bus_we) h.w = true; else h.r = true;
        }
        if (top->cpu_error != err_prev) {
            uint8_t rising = top->cpu_error & ~err_prev;
            for (int b = 0; b < 6; b++) if (rising & (1u << b)) err_count[b]++;
            err_prev = top->cpu_error;
        }

        const std::string &td = g_dev.testdev.out;
        while (td_seen < td.size()) {
            char c = td[td_seen++];
            if (c != '\r') console.push_back(c);
        }

        top->clk = 0; top->eval();
        cycle++;
    };

    bool done = false;
    while (!done) {
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            ImGui_ImplSDL2_ProcessEvent(&ev);
            if (ev.type == SDL_QUIT) done = true;
            if (ev.type == SDL_WINDOWEVENT && ev.window.event == SDL_WINDOWEVENT_CLOSE &&
                ev.window.windowID == SDL_GetWindowID(window)) done = true;
            if (ev.type == SDL_KEYDOWN && !ImGui::GetIO().WantCaptureKeyboard) {
                if (ev.key.keysym.sym == SDLK_F5)  running = !running;
                if (ev.key.keysym.sym == SDLK_F11) step_once = true;
                if (ev.key.keysym.sym == SDLK_F6)  step_many = true;
            }
        }

        if (step_once) { step_cycle(); step_once = false; }
        if (step_many) { for (int i = 0; i < 5000; i++) step_cycle(); step_many = false; }
        if (running)   { for (int i = 0; i < step_batch; i++) step_cycle(); }

        uint32_t now = SDL_GetTicks();
        if (now - last_rate_ms >= 500) {
            cycles_per_sec = (cycle - last_cycle_mark) * 1000.0 / (now - last_rate_ms);
            last_cycle_mark = cycle;
            last_rate_ms = now;
        }

        ImGui_ImplOpenGL2_NewFrame();
        ImGui_ImplSDL2_NewFrame(window);
        ImGui::NewFrame();

        // ---- Control -----------------------------------------------------
        ImGui::Begin("Control");
        ImGui::Text("%s", load_msg.empty() ? "(nothing loaded)" : load_msg.c_str());
        ImGui::Text("boot PC %08X   RAM %u MB   testdev %s",
                    boot_pc, ram_mb, testdev ? "yes" : "no");
        ImGui::Separator();
        if (ImGui::Button(running ? "Stop (F5)" : "Run (F5)")) running = !running;
        ImGui::SameLine(); if (ImGui::Button("Step (F11)"))  step_once = true;
        ImGui::SameLine(); if (ImGui::Button("5000 (F6)"))   step_many = true;
        ImGui::SameLine(); if (ImGui::Button("Reset")) {
            delete top;
            top = new Vsim_top;
            top->reset = 1; top->sclk = 0; top->clk = 0;
            top->boot_pc = boot_pc; top->gio_present = testdev ? 1 : 0; top->rxdb = 1;
            cycle = 0; console.clear(); trace.clear(); hot.clear(); holes.clear();
            urx = UartRx(); utx = UartTx(); td_seen = 0; err_prev = 0;
            for (int b = 0; b < 6; b++) err_count[b] = 0;
            g_dev.testdev.out.clear(); g_dev.testdev.exited = false;
        }
        ImGui::Text("cycle %llu   %.2f Mcycles/s",
                    (unsigned long long)cycle, cycles_per_sec / 1e6);
        ImGui::SliderInt("cycles per frame", &step_batch, 1000, 2000000);
        ImGui::Separator();
        // cpu_error is a set of N64 debugging aids, not faults: the test suite
        // raises most of them on purpose. Counted, never fatal here.
        ImGui::Text("cpu_error (informational):");
        for (int b = 0; b < 6; b++)
            if (err_count[b])
                ImGui::Text("  %-24s %llu", kErrorNames[b], (unsigned long long)err_count[b]);
        ImGui::End();

        // ---- Console -----------------------------------------------------
        ImGui::Begin("Console (SCC channel B / tty1)");
        ImGui::Text("%zu bytes printed   wire bit time %llu clocks",
                    console.size(), (unsigned long long)urx.bit_time);
        ImGui::BeginChild("con", ImVec2(0, -60), true, ImGuiWindowFlags_HorizontalScrollbar);
        ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0, 1));
        ImGui::TextUnformatted(console.c_str(), console.c_str() + console.size());
        ImGui::PopStyleVar();
        if (running) ImGui::SetScrollHereY(1.0f);
        ImGui::EndChild();
        bool can_type = urx.bit_time != 0;
        if (!can_type)
            ImGui::TextDisabled("type: waiting for the machine to transmit, to measure the bit rate");
        ImGui::BeginDisabled(!can_type);
        ImGui::PushItemWidth(-80);
        if (ImGui::InputText("##type", type_buf, sizeof(type_buf),
                             ImGuiInputTextFlags_EnterReturnsTrue)) {
            for (char *p = type_buf; *p; p++) utx.queue.push_back((uint8_t)*p);
            utx.queue.push_back('\r');
            type_buf[0] = 0;
            ImGui::SetKeyboardFocusHere(-1);
        }
        ImGui::PopItemWidth();
        ImGui::SameLine();
        ImGui::Text("%zu queued", utx.queue.size());
        ImGui::EndDisabled();
        ImGui::End();

        // ---- Bus trace ---------------------------------------------------
        ImGui::Begin("Bus trace");
        ImGui::Checkbox("record", &trace_on);
        ImGui::SameLine(); if (ImGui::Button("clear")) trace.clear();
        ImGui::SameLine(); ImGui::Text("%zu of %zu", trace.size(), trace_cap);
        ImGui::BeginChild("tr", ImVec2(0, 0), false, ImGuiWindowFlags_HorizontalScrollbar);
        ImGuiListClipper clip;
        clip.Begin((int)trace.size());
        while (clip.Step())
            for (int i = clip.DisplayStart; i < clip.DisplayEnd; i++) {
                const Txn &t = trace[i];
                ImGui::Text("%10llu %s %08X %-14s %016llX be %02X",
                            (unsigned long long)t.cycle, t.we ? "WR" : "RD", t.addr,
                            reg_name(t.addr), (unsigned long long)t.data, t.be);
            }
        if (running) ImGui::SetScrollHereY(1.0f);
        ImGui::EndChild();
        ImGui::End();

        // ---- Holes -------------------------------------------------------
        ImGui::Begin("Unclaimed addresses");
        ImGui::TextWrapped("Bus cycles no device answered. This is the live map of "
                           "what is still missing - the next thing to build is "
                           "usually the address at the top of a poll loop.");
        if (ImGui::Button("clear")) holes.clear();
        ImGui::BeginChild("ho", ImVec2(0, 0));
        for (const auto &e : holes)
            ImGui::Text("%08X %-16s %-3s x%-8llu  first %llu last %llu",
                        e.first, reg_name(e.first),
                        e.second.r && e.second.w ? "R/W" : e.second.w ? "W" : "R",
                        (unsigned long long)e.second.count,
                        (unsigned long long)e.second.first,
                        (unsigned long long)e.second.last);
        ImGui::EndChild();
        ImGui::End();

        // ---- Hot ---------------------------------------------------------
        ImGui::Begin("Hot addresses");
        if (ImGui::Button("clear")) hot.clear();
        std::vector<std::pair<uint32_t, uint64_t>> v(hot.begin(), hot.end());
        std::sort(v.begin(), v.end(),
                  [](const auto &a, const auto &b) { return a.second > b.second; });
        ImGui::BeginChild("ht", ImVec2(0, 0));
        for (size_t i = 0; i < v.size() && i < 40; i++)
            ImGui::Text("%08X %-16s %llu", v[i].first, reg_name(v[i].first),
                        (unsigned long long)v[i].second);
        ImGui::EndChild();
        ImGui::End();

        // ---- PROM patches ------------------------------------------------
        ImGui::Begin("PROM patches");
        ImGui::TextWrapped("Word patches applied to the loaded image. 0x00000000 is "
                           "NOP; 0x03E00008 is `jr $ra`. Answers to \"would it get "
                           "further without this\" - never a fix.");
        if (ImGui::Button("add")) patches.push_back({0x1FC00000, 0x00000000, false, ""});
        for (size_t i = 0; i < patches.size(); i++) {
            ImGui::PushID((int)i);
            ImGui::Checkbox("##en", &patches[i].enabled);
            ImGui::SameLine(); ImGui::PushItemWidth(90);
            ImGui::InputScalar("addr", ImGuiDataType_U32, &patches[i].addr, nullptr, nullptr, "%08X",
                               ImGuiInputTextFlags_CharsHexadecimal);
            ImGui::SameLine();
            ImGui::InputScalar("word", ImGuiDataType_U32, &patches[i].value, nullptr, nullptr, "%08X",
                               ImGuiInputTextFlags_CharsHexadecimal);
            ImGui::PopItemWidth();
            ImGui::SameLine(); ImGui::PushItemWidth(200);
            ImGui::InputText("note", patches[i].note, sizeof(patches[i].note));
            ImGui::PopItemWidth();
            ImGui::SameLine();
            if (ImGui::Button("apply") && patches[i].enabled) apply_patch(patches[i]);
            ImGui::PopID();
        }
        ImGui::TextDisabled("A patch only reaches the CPU after the next fetch of that "
                            "word, so reset after applying one that is already running.");
        ImGui::End();

        ram_edit.DrawWindow("RAM (physical 0x08000000)", g_dev.ram.bytes.data(),
                            g_dev.ram.size(), 0x08000000);
        prom_edit.DrawWindow("PROM (physical 0x1FC00000)", g_dev.prom.bytes.data(),
                             g_dev.prom.size(), 0x1FC00000);

        ImGui::Render();
        ImGuiIO &io = ImGui::GetIO();
        glViewport(0, 0, (int)io.DisplaySize.x, (int)io.DisplaySize.y);
        glClearColor(0.08f, 0.09f, 0.11f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        ImGui_ImplOpenGL2_RenderDrawData(ImGui::GetDrawData());
        SDL_GL_SwapWindow(window);
    }

    top->final();
    delete top;
    ImGui_ImplOpenGL2_Shutdown();
    ImGui_ImplSDL2_Shutdown();
    ImGui::DestroyContext();
    SDL_GL_DeleteContext(gl);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
