#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)

struct HierarchyParameters { uint count, originalCount, rankCount, directed, retainBest; float2 separation; uint action, iteration, rank, temporarySize; };

// Split coordinates keep geometric decisions precise without unsupported Metal doubles.
static float2 dsAdd(float2 a, float2 b) {
    float s = a.x + b.x, v = s - a.x;
    float e = (a.x - (s - v)) + (b.x - v) + a.y + b.y;
    float h = s + e; return float2(h, e - (h - s));
}
static float2 dsSub(float2 a, float2 b) { return dsAdd(a, -b); }
static bool dsLess(float2 a, float2 b) { return a.x < b.x || (a.x == b.x && a.y < b.y); }
static float2 dsMin(float2 a, float2 b) { return dsLess(a, b) ? a : b; }
static float2 dsMax(float2 a, float2 b) { return dsLess(a, b) ? b : a; }
static float2 dsAbs(float2 a) { return dsLess(a, float2(0)) ? -a : a; }
static float2 dsDivide(float2 a, float denominator) {
    float q = a.x / denominator;
    return dsAdd(float2(q, 0), float2((fma(-q, denominator, a.x) + a.y) / denominator, 0));
}
static float2 dsMultiply(float2 a, float multiplier) {
    float high = a.x * multiplier;
    return dsAdd(float2(high, 0), float2(fma(a.x, multiplier, -high) + a.y * multiplier, 0));
}

static bool geometryHorizontal(float4 a, float4 b) {
    return dsLess(dsAbs(dsSub(a.zw, b.zw)), float2(0.0001f, 2.5262124884e-12f));
}
static bool geometryCrossing(float4 a, float4 b, float4 c, float4 d, thread float4 &hit) {
    bool ah = geometryHorizontal(a, b), bh = geometryHorizontal(c, d);
    if (ah == bh) return false;
    float4 h = ah ? a : c, he = ah ? b : d, v = ah ? c : a, ve = ah ? d : b;
    float2 epsilon = float2(0.0001f, 2.5262124884e-12f);
    hit = float4(v.xy, h.zw);
    return dsLess(dsAdd(dsMin(h.xy, he.xy), epsilon), v.xy)
        && dsLess(v.xy, dsSub(dsMax(h.xy, he.xy), epsilon))
        && dsLess(dsAdd(dsMin(v.zw, ve.zw), epsilon), h.zw)
        && dsLess(h.zw, dsSub(dsMax(v.zw, ve.zw), epsilon));
}
static bool geometryShared(float4 a, float4 b, float4 c, float4 d) {
    bool ah = geometryHorizontal(a, b), bh = geometryHorizontal(c, d);
    if (ah != bh) return false;
    float2 epsilon = float2(0.0001f, 2.5262124884e-12f);
    float2 delta = ah ? dsSub(a.zw, c.zw) : dsSub(a.xy, c.xy);
    float2 overlap = ah ? dsSub(dsMin(dsMax(a.xy, b.xy), dsMax(c.xy, d.xy)), dsMax(dsMin(a.xy, b.xy), dsMin(c.xy, d.xy)))
        : dsSub(dsMin(dsMax(a.zw, b.zw), dsMax(c.zw, d.zw)), dsMax(dsMin(a.zw, b.zw), dsMin(c.zw, d.zw)));
    return dsLess(dsAbs(delta), epsilon) && dsLess(epsilon, overlap);
}

// One independent node/segment pair per thread. The host chunks pair ranges and
// drains each command before releasing its leased buffers on cancellation.
kernel void directedGeometry(device const float4 *points [[buffer(0)]], device const uint4 *pairs [[buffer(1)]],
    device uint4 *counts [[buffer(2)]], device const uint2 *pointIDs [[buffer(3)]],
    device const uint2 *boundIDs [[buffer(4)]], constant uint &count [[buffer(5)]], uint index [[thread_position_in_grid]]) {
    if (index >= count) return;
    uint4 pair = pairs[index]; uint i = pair.x, j = pair.y;
    if (pair.z == 0) {
        uint2 a = boundIDs[2 * i], ae = boundIDs[2 * i + 1], b = boundIDs[2 * j], be = boundIDs[2 * j + 1];
        counts[index] = uint4(a.x < be.x && b.x < ae.x && a.y < be.y && b.y < ae.y, 0, 0, 0);
        return;
    }
    float4 hit;
    bool crossing = geometryCrossing(points[i], points[i + 1], points[j], points[j + 1], hit);
    bool shared = geometryShared(points[i], points[i + 1], points[j], points[j + 1]);
    bool horizontal = geometryHorizontal(points[i], points[i + 1]);
    uint2 hitID = horizontal ? uint2(pointIDs[j].x, pointIDs[i].y) : uint2(pointIDs[i].x, pointIDs[j].y);
    counts[index] = uint4((crossing ? 1 : 0) | (shared ? 2 : 0), hitID.x, hitID.y, 0);
}

static ulong hierarchyCrossings(device const uint *layers, device const uint *rankOffsets,
    device const uint *order, device const uint *outOffsets, device const uint *outgoing,
    device uint *tree, uint rankCount) {
    ulong result = 0;
    for (uint rank = 0; rank + 1 < rankCount; ++rank) {
        uint size = rankOffsets[rank + 2] - rankOffsets[rank + 1];
        for (uint i = 0; i <= size; ++i) tree[i] = 0;
        uint seen = 0;
        for (uint p = rankOffsets[rank]; p < rankOffsets[rank + 1]; ++p) {
            uint node = layers[p];
            for (uint k = outOffsets[node]; k < outOffsets[node + 1]; ++k) {
                uint i = order[outgoing[k]] + 1, prefix = 0;
                while (i > 0) { prefix += tree[i]; i -= i & -i; }
                result += seen - prefix;
            }
            for (uint k = outOffsets[node]; k < outOffsets[node + 1]; ++k) {
                uint i = order[outgoing[k]] + 1;
                while (i <= size) { tree[i] += 1; i += i & -i; }
                ++seen;
            }
        }
    }
    return result;
}

// Ordering is intentionally serial: CPU rank sweeps update order immediately,
// and parallel Jacobi sweeps would change deterministic layout decisions.
kernel void hierarchyOrder(device uint *layers [[buffer(0)]], device const uint *rankOffsets [[buffer(1)]],
    device const uint *inOffsets [[buffer(2)]], device const uint *incoming [[buffer(3)]],
    device const uint *outOffsets [[buffer(4)]], device const uint *outgoing [[buffer(5)]],
    device uint *scratch [[buffer(6)]], constant HierarchyParameters &p [[buffer(7)]], uint threadIndex [[thread_position_in_grid]]) {
    if (threadIndex != 0) return;
    device uint *order = scratch, *best = scratch + p.count, *median = scratch + p.count * 2;
    device uint *temp = scratch + p.count * 3;
    device uint *meta = temp + p.temporarySize;
    if (p.action == 0) {
        for (uint rank = 0; rank < p.rankCount; ++rank)
            for (uint i = rankOffsets[rank]; i < rankOffsets[rank + 1]; ++i) order[layers[i]] = i - rankOffsets[rank];
        for (uint i = 0; i < p.count; ++i) best[i] = layers[i];
        ulong crossings = p.directed ? hierarchyCrossings(layers, rankOffsets, order, outOffsets, outgoing, temp, p.rankCount) : 0;
        meta[0] = uint(crossings); meta[1] = uint(crossings >> 32); meta[2] = 0;
    }
    if (p.action == 1) {
        bool forward = (p.iteration % 2) == 0, changed = false;
        uint rank = p.rank;
        device const uint *offsets = forward ? inOffsets : outOffsets;
        device const uint *neighbors = forward ? incoming : outgoing;
        uint start = rankOffsets[rank], end = rankOffsets[rank + 1];
        for (uint i = start; i < end; ++i) {
            uint node = layers[i], degree = offsets[node + 1] - offsets[node];
            for (uint k = 0; k < degree; ++k) {
                uint value = order[neighbors[offsets[node] + k]], at = k;
                while (at > 0 && temp[at - 1] > value) { temp[at] = temp[at - 1]; --at; }
                temp[at] = value;
            }
            median[node] = degree == 0 ? 2 * order[node] : temp[(degree - 1) / 2] + temp[degree / 2];
        }
        for (uint i = start + 1; i < end; ++i) {
            uint node = layers[i], at = i;
            while (at > start && median[layers[at - 1]] > median[node]) {
                layers[at] = layers[at - 1]; --at; changed = true;
            }
            layers[at] = node;
        }
        for (uint i = start; i < end; ++i) order[layers[i]] = i - start;
        meta[2] = changed ? 1 : 0;
    }
    if (p.action == 2 && p.directed) {
        ulong bestCrossings = ulong(meta[0]) | (ulong(meta[1]) << 32);
        ulong crossings = hierarchyCrossings(layers, rankOffsets, order, outOffsets, outgoing, temp, p.rankCount);
        if (crossings < bestCrossings) {
            meta[0] = uint(crossings); meta[1] = uint(crossings >> 32);
            for (uint i = 0; i < p.count; ++i) best[i] = layers[i];
        }
    }
    if (p.action == 3 && p.directed && p.retainBest) {
        for (uint i = 0; i < p.count; ++i) layers[i] = best[i];
        for (uint rank = 0; rank < p.rankCount; ++rank)
            for (uint i = rankOffsets[rank]; i < rankOffsets[rank + 1]; ++i) order[layers[i]] = i - rankOffsets[rank];
    }
    if (p.action == 4 && p.directed) {
        bool changed = false;
        uint rank = p.rank, start = rankOffsets[rank], end = rankOffsets[rank + 1];
        for (uint i = start; i + 1 < end; ++i) {
            uint u = layers[i], v = layers[i + 1];
            ulong before = 0, after = 0;
            for (uint direction = 0; direction < 2; ++direction) {
                device const uint *offsets = direction == 0 ? inOffsets : outOffsets;
                device const uint *neighbors = direction == 0 ? incoming : outgoing;
                for (uint a = offsets[u]; a < offsets[u + 1]; ++a)
                    for (uint b = offsets[v]; b < offsets[v + 1]; ++b) {
                        before += order[neighbors[a]] > order[neighbors[b]];
                        after += order[neighbors[a]] < order[neighbors[b]];
                    }
            }
            if (after < before) {
                layers[i] = v; layers[i + 1] = u;
                order[u] = i + 1 - start; order[v] = i - start; changed = true;
            }
        }
        meta[2] = changed ? 1 : 0;
    }
}

kernel void hierarchyPlacement(device const uint *layers [[buffer(0)]], device const uint *rankOffsets [[buffer(1)]],
    device const uint *inOffsets [[buffer(2)]], device const uint *incoming [[buffer(3)]],
    device const uint *outOffsets [[buffer(4)]], device const uint *outgoing [[buffer(5)]],
    device const float2 *widths [[buffer(6)]], device float2 *scratch [[buffer(7)]],
    device uint *blocks [[buffer(8)]], device uint *ends [[buffer(9)]],
    constant HierarchyParameters &p [[buffer(10)]], device uint *mergeCounts [[buffer(11)]], uint threadIndex [[thread_position_in_grid]]) {
    if (threadIndex != 0) return;
    device float2 *xs = scratch, *shift = scratch + p.count, *sum = scratch + p.count * 2;
    device float2 *weights = scratch + p.count * 3;
    device uint *first = blocks, *last = blocks + p.count;
    if (p.action == 5) for (uint rank = 0; rank < p.rankCount; ++rank) {
        uint start = rankOffsets[rank], end = rankOffsets[rank + 1];
        float2 total = float2(0);
        for (uint i = start; i < end; ++i) total = dsAdd(total, widths[layers[i]]);
        total = dsAdd(total, dsMultiply(p.separation, float(end - start - 1)));
        float2 x = -total / 2;
        for (uint i = start; i < end; ++i) { uint node = layers[i]; xs[node] = dsAdd(x, widths[node] / 2); x = dsAdd(x, dsAdd(widths[node], p.separation)); }
    }
    if (p.action == 6) {
        uint pass = p.iteration;
        {
            uint rank = p.rank;
            uint start = rankOffsets[rank], end = rankOffsets[rank + 1], count = 0;
            float2 distance = float2(0);
            for (uint i = start; i < end; ++i) {
                uint node = layers[i], position = i - start;
                if (i > start) distance = dsAdd(distance, dsAdd(dsAdd(widths[layers[i - 1]], widths[node]) / 2, p.separation));
                shift[position] = distance;
                uint degree = inOffsets[node + 1] - inOffsets[node] + outOffsets[node + 1] - outOffsets[node];
                float2 desired = float2(0);
                for (uint j = inOffsets[node]; j < inOffsets[node + 1]; ++j) desired = dsAdd(desired, xs[incoming[j]]);
                for (uint j = outOffsets[node]; j < outOffsets[node + 1]; ++j) desired = dsAdd(desired, xs[outgoing[j]]);
                desired = dsSub(degree == 0 ? xs[node] : dsDivide(desired, float(degree)), distance);
                first[count] = position; last[count] = position;
                weights[count] = float2(node < p.originalCount ? 1 : 4, 0);
                sum[count] = desired * weights[count].x; ++count; uint merges = 0;
                while (count > 1 && dsLess(dsDivide(sum[count - 1], weights[count - 1].x), dsDivide(sum[count - 2], weights[count - 2].x))) {
                    last[count - 2] = last[count - 1];
                    sum[count - 2] = dsAdd(sum[count - 2], sum[count - 1]); weights[count - 2].x += weights[count - 1].x; --count; ++merges;
                }
                mergeCounts[pass * p.count + node] = merges;
            }
            for (uint b = 0; b < count; ++b) for (uint i = first[b]; i <= last[b]; ++i) {
                uint node = layers[start + i];
                xs[node] = dsAdd(dsDivide(sum[b], weights[b].x), shift[i]); ends[pass * p.count + node] = last[b];
            }
        }
    }
}
