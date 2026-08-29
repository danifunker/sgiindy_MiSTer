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
#include <cstdio>
#include <cstring>
#include <string>
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
    // Displayed pixels with a non-zero value in each channel, over the whole
    // run. A CHANNEL THAT IS IDENTICALLY ZERO IS A BUG AND NOT A PICTURE, and
    // it is not one you can see in the frame buffer dump: the store holds a
    // colour index, so a Display Control Bus that dropped the third byte of
    // every palette write left the store perfect and every colour on the
    // screen without its blue. The whole boot screen came out yellow-green
    // and nothing failed.
    uint64_t chan[3] = {0, 0, 0};
    bool     de_d = false;

    VideoCapture() { fb.assign((size_t)MAXW * MAXH, 0xFF000000u); }

    void clear() {
        std::fill(fb.begin(), fb.end(), 0xFF000000u);
        x = y = seen_w = seen_h = cur_w = 0;
        frames = lit = lit_run = 0;
        best_w = best_h = 0;
        hsyncs = vsyncs = de_rises = de_pixels = 0;
        chan[0] = chan[1] = chan[2] = 0;
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
        if (ce && de) {
            de_pixels++;
            if (r) chan[0]++;
            if (g) chan[1]++;
            if (b) chan[2]++;
        }

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

// What came out of the PINS, as a binary PPM. THIS IS NOT THE SAME PICTURE AS
// --fbdump AND THE DIFFERENCE IS THE POINT: --fbdump shows the store, which is
// an 8-bit colour index that dump_framebuffer_ppm renders as grey, while this
// is the index after XMAP9's mode table chose how to read it and CMAP turned
// it into 24 bits of colour. A fault in the palette, in the mode table, or in
// the channel order of the readout is invisible in one and obvious in the
// other.
//
// `w` and `h` come from the largest frame seen rather than from the buffer's
// stride, so what lands in the file is one frame of whatever geometry the
// machine actually produced.
inline bool dump_video_ppm(const std::string &path, const VideoCapture &vc)
{
    int w = vc.best_w, h = vc.best_h;
    if (w <= 0 || h <= 0) return false;
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) return false;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    std::vector<uint8_t> row((size_t)w * 3);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            uint32_t px = vc.fb[(size_t)y * VideoCapture::MAXW + x];
            row[(size_t)x * 3 + 0] = (uint8_t)(px & 0xFF);          // r
            row[(size_t)x * 3 + 1] = (uint8_t)((px >> 8) & 0xFF);   // g
            row[(size_t)x * 3 + 2] = (uint8_t)((px >> 16) & 0xFF);  // b
        }
        fwrite(row.data(), 1, row.size(), f);
    }
    fclose(f);
    return true;
}

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
