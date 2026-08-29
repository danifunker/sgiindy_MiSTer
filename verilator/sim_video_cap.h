// sim_video_cap.h - capture the core's video output into a frame the GUI can
// draw.
//
// This deliberately watches the OUTPUT PINS - ce_pix, de, hsync, vsync and the
// three colour buses - rather than reading the frame buffer store. A picture
// built from the frame buffer would look right even if VC2's timing generator
// were emitting nonsense; a picture built from the pins is only right if the
// whole chain worked: the timing table walk, the display enable, the frame
// buffer read port, XMAP9's mode table and CMAP's palette.
//
// The GUI can also show the raw frame buffer, and the two together are the
// bring-up tool: pixels in the store but not on the pins is a video timing
// problem, and nothing in either is a rasteriser problem.
#pragma once
#include <cstdint>
#include <cstring>
#include <vector>

struct VideoCapture {
    static constexpr int MAXW = 2048;
    static constexpr int MAXH = 1200;

    std::vector<uint32_t> fb;          // RGBA8888, MAXW stride
    int      x = 0, y = 0;
    int      seen_w = 0, seen_h = 0;   // extent of the last complete frame
    // The largest frame seen. The last one is not a good measure on a boot:
    // the PROM soft-resets VC2 and reloads its tables more than once, so a
    // frame that straddles a reconfiguration is short through no fault of the
    // timing generator. What the biggest frame was answers "did this machine
    // ever put a whole picture out", which is the question.
    int      best_w = 0, best_h = 0;
    int      cur_w = 0;
    uint64_t frames = 0;
    uint64_t lit = 0;                  // non-black pixels in the last frame
    uint64_t lit_run = 0;
    bool     hs_d = false, vs_d = false;
    bool     dirty = false;
    // Raw edge counts over the whole run. Lines per frame and pixels per line
    // are ratios of these, and a ratio is what tells you whether the timing
    // generator is walking the table or wandering through it.
    uint64_t hsyncs = 0, vsyncs = 0, de_rises = 0, de_pixels = 0;
    bool     de_d = false;

    VideoCapture() { fb.assign((size_t)MAXW * MAXH, 0xFF000000u); }

    void clear() {
        std::fill(fb.begin(), fb.end(), 0xFF000000u);
        x = y = seen_w = seen_h = cur_w = 0;
        frames = lit = lit_run = 0;
        best_w = best_h = 0;
        hsyncs = vsyncs = de_rises = de_pixels = 0;
        dirty = true;
    }

    // Call once per core clock, after eval().
    void step(bool ce, bool de, bool hs, bool vs,
              uint8_t r, uint8_t g, uint8_t b)
    {
        // Sync edges first: a pixel never lands on the same clock as the edge
        // that ends its line.
        if (de && !de_d) de_rises++;
        de_d = de;
        if (hs && !hs_d) hsyncs++;
        if (vs && !vs_d) vsyncs++;
        if (ce && de) de_pixels++;

        if (vs && !vs_d) {
            seen_h  = y;
            seen_w  = cur_w;
            if (y     > best_h) best_h = y;
            if (cur_w > best_w) best_w = cur_w;
            lit     = lit_run;
            lit_run = 0;
            frames++;
            y = 0; x = 0; cur_w = 0;
            dirty = true;
        } else if (hs && !hs_d) {
            if (x > cur_w) cur_w = x;
            if (y < MAXH - 1) y++;
            x = 0;
        }
        hs_d = hs; vs_d = vs;

        if (ce && de && x < MAXW && y < MAXH) {
            uint32_t px = 0xFF000000u | ((uint32_t)b << 16) | ((uint32_t)g << 8) | r;
            fb[(size_t)y * MAXW + x] = px;
            if (r || g || b) lit_run++;
            x++;
        }
    }
};

// The frame buffer store as the rasteriser left it, without going through the
// video path. Eight bytes a pixel: the drawing planes in the low word and the
// auxiliary planes in the high one. `palette` is CMAP page zero when the guest
// has loaded one, and nullptr means show the raw index as grey.
inline void vram_to_rgba(const uint8_t *vram, size_t vram_bytes,
                         int w, int h, int stride,
                         bool as_index, uint32_t *out, int out_stride)
{
    for (int yy = 0; yy < h; yy++) {
        for (int xx = 0; xx < w; xx++) {
            size_t off = ((size_t)yy * stride + xx) * 8;
            uint32_t px = 0xFF000000u;
            if (off + 8 <= vram_bytes) {
                // Big-endian store: byte 4 is the top of the low word.
                uint32_t rgb = ((uint32_t)vram[off + 5] << 16)
                             | ((uint32_t)vram[off + 6] << 8)
                             |  (uint32_t)vram[off + 7];
                if (as_index) {
                    uint8_t i = (uint8_t)(rgb & 0xFF);
                    px |= ((uint32_t)i << 16) | ((uint32_t)i << 8) | i;
                } else {
                    // 0x00BBGGRR in the store, RGBA out.
                    px |= ((rgb & 0xFF0000)) | (rgb & 0x00FF00) | (rgb & 0x0000FF);
                }
            }
            out[(size_t)yy * out_stride + xx] = px;
        }
    }
}
