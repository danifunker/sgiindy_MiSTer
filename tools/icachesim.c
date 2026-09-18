/*
 * icachesim - replay the simulator's instruction-cache access stream through
 * other cache geometries (docs/design/cpu-speed-tlb-icache.md).
 *
 *   ./obj_wm2/Vsim_top ... --itrace itrace.bin
 *   cc -O2 -o icachesim tools/icachesim.c
 *   ./icachesim itrace.bin [window-records]
 *
 * The trace is what `sim_cputest --itrace` writes: one little-endian uint32
 * per access, the physical address >> 5 (a 32-byte line), consecutive
 * repeats collapsed. Every line is a hit or a miss in every geometry below,
 * and a miss is a fill - one DDR3 round trip on the board. The kernel's
 * cache flushes are not in the stream, so every geometry is missing the
 * same few forced misses; the simulator's own fill counter (perf word 4)
 * against the direct-mapped 16 KB line here is the check on that.
 *
 * Geometries: direct-mapped 8/16/32/64 KB, two-way 2x8/2x16/2x32 KB and
 * four-way 4x8 KB (LRU), plus a 16 KB direct-mapped cache in front of a
 * direct-mapped second level of 64/128/256 KB of block RAM, where the
 * question is how many first-level misses the second level would answer
 * without a DDR3 trip.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EMPTY 0xFFFFFFFFu

typedef struct {
    const char *name;
    unsigned sets, ways;
    uint32_t *tag;      /* sets * ways, most recent first */
    uint64_t misses, win_misses;
} Cache;

static Cache mk(const char *name, unsigned sets, unsigned ways)
{
    Cache c = { name, sets, ways, NULL, 0, 0 };
    c.tag = malloc(sizeof(uint32_t) * sets * ways);
    for (unsigned i = 0; i < sets * ways; i++) c.tag[i] = EMPTY;
    return c;
}

/* Look a line up; on a miss, fill it over the least recently used way.
   Returns 1 on a hit. */
static int access_line(Cache *c, uint32_t line)
{
    uint32_t *t = &c->tag[(line & (c->sets - 1)) * c->ways];
    for (unsigned w = 0; w < c->ways; w++) {
        if (t[w] == line) {
            memmove(&t[1], &t[0], w * sizeof(uint32_t));
            t[0] = line;
            return 1;
        }
    }
    memmove(&t[1], &t[0], (c->ways - 1) * sizeof(uint32_t));
    t[0] = line;
    c->misses++;
    c->win_misses++;
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s itrace.bin [window-records]\n", argv[0]);
        return 2;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    uint64_t window = argc > 2 ? strtoull(argv[2], NULL, 0) : 0;

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

    /* 16 KB DM first level, direct-mapped second levels behind it. */
    Cache l1 = mk("L1 DM 16K", 512, 1);
    Cache l2[] = {
        mk("+L2 64K",   2048, 1),
        mk("+L2 128K",  4096, 1),
        mk("+L2 256K",  8192, 1),
    };
    const unsigned NL2 = sizeof l2 / sizeof l2[0];
    uint64_t l2_trip[3] = { 0, 0, 0 };   /* L1 and L2 both missed */

    uint32_t buf[1 << 16];
    uint64_t n = 0, win_n = 0;
    size_t got;
    if (window) {
        printf("%12s", "records");
        for (unsigned i = 0; i < NC; i++) printf(" %9s", c[i].name);
        printf("   (misses per 1000 records in each window)\n");
    }
    while ((got = fread(buf, sizeof(uint32_t), sizeof buf / sizeof buf[0], f)) > 0) {
        for (size_t k = 0; k < got; k++) {
            uint32_t line = buf[k];
            for (unsigned i = 0; i < NC; i++) access_line(&c[i], line);
            int h1 = access_line(&l1, line);
            for (unsigned i = 0; i < NL2; i++) {
                /* A second level is only consulted, and only filled, on a
                   first-level miss - it sees the stream that falls through. */
                if (!h1 && !access_line(&l2[i], line)) l2_trip[i]++;
            }
            n++;
            if (window && ++win_n == window) {
                printf("%12llu", (unsigned long long)n);
                for (unsigned i = 0; i < NC; i++) {
                    printf(" %9.2f", 1000.0 * c[i].win_misses / win_n);
                    c[i].win_misses = 0;
                }
                printf("\n");
                win_n = 0;
            }
        }
    }
    fclose(f);

    printf("\n%llu records (line changes)\n\n", (unsigned long long)n);
    printf("%-10s %12s %10s %8s\n", "geometry", "misses", "/1000 rec", "vs DM16K");
    for (unsigned i = 0; i < NC; i++)
        printf("%-10s %12llu %10.3f %7.1f%%\n", c[i].name,
               (unsigned long long)c[i].misses, 1000.0 * c[i].misses / (n ? n : 1),
               100.0 * c[i].misses / (c[1].misses ? c[1].misses : 1));
    printf("\n%-10s %12s %10s %12s\n", "L1 DM 16K", "L1 misses", "L2 answers", "DDR3 trips");
    for (unsigned i = 0; i < NL2; i++)
        printf("%-10s %12llu %10.1f%% %12llu\n", l2[i].name,
               (unsigned long long)l1.misses,
               100.0 * (l1.misses - l2_trip[i]) / (l1.misses ? l1.misses : 1),
               (unsigned long long)l2_trip[i]);
    return 0;
}
