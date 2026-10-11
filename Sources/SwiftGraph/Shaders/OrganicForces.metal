#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)

struct Parameters {
    uint count;
    float temperature;
    float repulsionSquared;
    float attraction;
};

// One node per lane. All lanes participate in barriers, including the padded tail.
// Two position buffers prevent threads from reading partially updated coordinates.
kernel void organicStep(
    device const float2* positions [[buffer(0)]],
    device float2* output [[buffer(1)]],
    device const uint* fixed [[buffer(2)]],
    device const uint* offsets [[buffer(3)]],
    device const uint* neighbors [[buffer(4)]],
    constant Parameters& params [[buffer(5)]],
    uint id [[thread_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]]) {
    threadgroup float2 tile[128];
    bool active = id < params.count;
    float2 point = active ? positions[id] : float2(0);
    float2 force(0);
    for (uint base = 0; base < params.count; base += 128) {
        uint source = base + lane;
        tile[lane] = source < params.count ? positions[source] : float2(0);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (active && !fixed[id]) {
            uint length = min(128u, params.count - base);
            for (uint k = 0; k < length; ++k) {
                uint other = base + k;
                if (other == id) continue;
                float2 delta = point - tile[k];
                float squared = delta.x * delta.x + delta.y * delta.y;
                if (squared < 0.01f) {
                    delta = float2(id > other ? 0.1f : -0.1f);
                    squared = 0.02f;
                }
                if (squared <= 250000.0f) force += delta * (params.repulsionSquared / squared);
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (!active) return;
    if (fixed[id]) { output[id] = point; return; }
    for (uint k = offsets[id]; k < offsets[id + 1]; ++k) {
        force += (positions[neighbors[k]] - point) * params.attraction;
    }
    float distance = sqrt(force.x * force.x + force.y * force.y);
    output[id] = distance > 0.1f ? point + force * (min(distance, params.temperature) / distance) : point;
}
