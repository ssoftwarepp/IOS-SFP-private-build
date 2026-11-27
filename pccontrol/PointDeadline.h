#ifndef ZX_POINT_DEADLINE_H
#define ZX_POINT_DEADLINE_H
#include <stdint.h>
#include <math.h>
// Shared production/test deadline decisions. Times are continuous monotonic ns.
static const uint64_t zxPointQueueNS = 750000000ULL;
static const uint64_t zxPointTotalNS = 3000000000ULL;
static const uint64_t zxPointReserveNS = 250000000ULL;
static inline int zxPointDeadlineCode(uint64_t start, uint64_t now, bool running,
                                     bool workBoundary) {
    const uint64_t elapsed = now >= start ? now - start : 0;
    if (!running && elapsed >= zxPointQueueNS) return 3411;
    if (running && elapsed >= zxPointTotalNS - (workBoundary ? zxPointReserveNS : 0))
        return 3412;
    return 0;
}
static inline float zxPointTimeoutSeconds(uint64_t start, uint64_t now) {
    const uint64_t elapsed = now >= start ? now - start : 0;
    const uint64_t work = zxPointTotalNS - zxPointReserveNS;
    if (elapsed >= work || work - elapsed <= 25000000ULL) return 0;
    const double seconds = (work - elapsed - 20000000ULL) / 1000000000.0;
    return (float)fmin(0.5, seconds);
}
#endif
