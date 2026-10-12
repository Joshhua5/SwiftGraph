#include <metal_stdlib>
using namespace metal;
// Two non-overlapping Float components retain roughly 48 significant bits. Fast math is
// disabled by the resource compiler; explicit fma supplies the product's rounding residual.
inline float2 ds_normalize(float high, float low) { float sum = high + low; return float2(sum, low - (sum - high)); }
inline float2 ds_add(float2 a, float2 b) {
    float sum = a.x + b.x, v = sum - a.x;
    float error = (a.x - (sum - v)) + (b.x - v);
    return ds_normalize(sum, error + a.y + b.y);
}
inline float2 ds_multiply(float2 a, float2 b) {
    float product = a.x * b.x;
    float error = fma(a.x, b.x, -product) + a.x * b.y + a.y * b.x + a.y * b.y;
    return ds_normalize(product, error);
}
inline float2 ds_divide(float2 a, float divisor) {
    float quotient = a.x / divisor;
    float2 remainder = ds_add(a, -ds_multiply(float2(quotient, 0.0f), float2(divisor, 0.0f)));
    return ds_normalize(quotient, (remainder.x + remainder.y) / divisor);
}
struct RankParameters { uint count; uint padding; float2 base; float2 damping; };
kernel void pageRankDangling(device const float2* ranks [[buffer(0)]], device const uint* degree [[buffer(1)]], device float2* dangling [[buffer(2)]], constant RankParameters& p [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    if (i != 0) return;
    float2 sum = float2(0.0f);
    for (uint j = 0; j < p.count; ++j) if (degree[j] == 0) sum = ds_add(sum, ranks[j]);
    dangling[0] = ds_divide(sum, float(p.count));
}
kernel void pageRankStep(device const float2* ranks [[buffer(0)]], device float2* output [[buffer(1)]], device const uint* degree [[buffer(2)]], device const uint* offsets [[buffer(3)]], device const uint* incoming [[buffer(4)]], device const float2* dangling [[buffer(5)]], constant RankParameters& p [[buffer(6)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.count) return;
    float2 links = float2(0.0f);
    for (uint k = offsets[i]; k < offsets[i + 1]; ++k) { uint j = incoming[k]; links = ds_add(links, ds_divide(ranks[j], float(degree[j]))); }
    output[i] = ds_add(p.base, ds_multiply(p.damping, ds_add(links, dangling[0])));
}
struct ClusterParameters { uint start; uint end; uint count; uint padding; };
kernel void orderedClusterVotes(device uint* labels [[buffer(0)]], device const uint* offsets [[buffer(1)]], device const uint* neighbors [[buffer(2)]], device const uint* order [[buffer(3)]], device uint* counts [[buffer(4)]], device uint* labelOrder [[buffer(5)]], device uint* changed [[buffer(6)]], constant ClusterParameters& p [[buffer(7)]], uint lane [[thread_position_in_grid]]) {
    if (lane != 0) return;
    for (uint position = p.start; position < p.end; ++position) {
        uint node = order[position], distinct = 0;
        for (uint k = offsets[node]; k < offsets[node + 1]; ++k) {
            uint label = labels[neighbors[k]];
            if (counts[label] == 0) labelOrder[distinct++] = label;
            ++counts[label];
        }
        uint best = labels[node], bestCount = counts[best];
        for (uint k = 0; k < distinct; ++k) { uint label = labelOrder[k]; if (counts[label] > bestCount) { best = label; bestCount = counts[label]; } }
        if (labels[node] != best) { labels[node] = best; changed[0] = 1; }
        for (uint k = 0; k < distinct; ++k) counts[labelOrder[k]] = 0;
    }
}
