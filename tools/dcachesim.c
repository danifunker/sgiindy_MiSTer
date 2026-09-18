/*
 * dcachesim - replay the simulator's data-cache access stream through other
 * cache geometries (docs/design/cpu-speed-tlb-icache.md). The data-side companion of icachesim.c.
 *
 *   ./obj_wm2/Vsim_top ... --dtrace dtrace.bin
 *   cc -O2 -o dcachesim tools/dcachesim.c
 *   ./dcachesim dtrace.bin
 *
 * The trace is what `sim_cputest --dtrace` writes: one little-endian uint32
 * per load or store that went to the data cache, (physical address >> 3) << 1
 * | store, exact repeats collapsed.
 *
 * A data-cache miss costs a line fill, and if the line it evicts was written
 * to, first a writeback: cpu_datacache.vhd writes all four doublewords of a
 * dirty line back, each as its own bus transaction. So for every geometry
 * this counts fills, dirty evictions (lines written back) and the beats that
 * takes - four per line as the cache does it now, and only the doublewords
 * actually written, which is what per-word dirty bits would send. The
 * kernel's own write-back cache operations are not in the stream.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EMPTY 0xFFFFFFFFu

typedef struct {
    uint32_t line;
    uint8_t  dirty;     /* bit per doubleword written since the fill */
} Way;

typedef struct {
    const char *name;
    unsigned sets, ways;
    Way *w;             /* sets * ways, most recent first */
    uint64_t fills, wb_lines, wb_words;
} Cache;

static Cache mk(const char *name, unsigned sets, unsigned ways)
{
    Cache c = { name, sets, ways, NULL, 0, 0, 0 };
    c.w = calloc(sets * ways, sizeof(Way));
    for (unsigned i = 0; i < sets * ways; i++) c.w[i].line = EMPTY;
    return c;
}

static void access_word(Cache *c, uint32_t word, int store)
{
    uint32_t line = word >> 2;
    uint8_t bit = (uint8_t)(1u << (word & 3));
    Way *t = &c->w[(line & (c->sets - 1)) * c->ways];
    unsigned w;
    for (w = 0; w < c->ways; w++)
        if (t[w].line == line) break;
    Way hit;
    if (w < c->ways) {
        hit = t[w];
    } else {
        /* miss: the least recently used way goes, written back if dirty */
        w = c->ways - 1;
        if (t[w].line != EMPTY && t[w].dirty) {
            c->wb_lines++;
            c->wb_words += (unsigned)__builtin_popcount(t[w].dirty);
        }
        c->fills++;
        hit.line = line;
        hit.dirty = 0;
    }
    if (store) hit.dirty |= bit;
    memmove(&t[1], &t[0], w * sizeof(Way));
    t[0] = hit;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s dtrace.bin\n", argv[0]);
        return 2;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }

    Cache c[] = {
        mk("DM 8K",      256, 1),
        mk("DM 16K",     512, 1),
        mk("DM 32K",    1024, 1),
        mk("DM 64K",    2048, 1),
        mk("2x8K",       256, 2),
        mk("2x16K",      512, 2),
        mk("2x32K",     1024, 2),
        mk("4x8K",       256, 4),
    };
    const unsigned NC = sizeof c / sizeof c[0];

    uint32_t buf[1 << 16];
    uint64_t n = 0, stores = 0;
    size_t got;
    while ((got = fread(buf, sizeof(uint32_t), sizeof buf / sizeof buf[0], f)) > 0) {
        for (size_t k = 0; k < got; k++) {
            uint32_t word = buf[k] >> 1;
            int store = buf[k] & 1;
            stores += store;
            for (unsigned i = 0; i < NC; i++) access_word(&c[i], word, store);
            n++;
        }
    }
    fclose(f);

    printf("%llu records (%llu stores)\n\n", (unsigned long long)n, (unsigned long long)stores);
    printf("%-8s %11s %9s %11s %11s %11s %11s\n", "geometry", "fills", "vs DM16K",
           "wb lines", "beats x4", "dirty only", "bus xacts");
    for (unsigned i = 0; i < NC; i++)
        printf("%-8s %11llu %8.1f%% %11llu %11llu %11llu %11llu\n", c[i].name,
               (unsigned long long)c[i].fills,
               100.0 * c[i].fills / (c[1].fills ? c[1].fills : 1),
               (unsigned long long)c[i].wb_lines,
               (unsigned long long)(4 * c[i].wb_lines),
               (unsigned long long)c[i].wb_words,
               (unsigned long long)(c[i].fills + 4 * c[i].wb_lines));
    printf("\nbus xacts = fills + 4 beats per dirty line, as the cache does it now;\n"
           "'dirty only' is the beats per-word dirty bits would leave.\n");
    return 0;
}
