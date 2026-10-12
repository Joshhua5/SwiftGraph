#include <metal_stdlib>
using namespace metal;
struct RoutingParameters { uint start; uint count; uint rightCount; uint padding; };
// Inputs are outward rounded on the host. Reject only disjoint bounding boxes; Double
// narrow-phase predicates retain closed boundaries, near-collinearity and search tie parity.
kernel void routingBoxCandidates(device const float4* left [[buffer(0)]], device const float4* right [[buffer(1)]], device uint* result [[buffer(2)]], constant RoutingParameters& p [[buffer(3)]], uint local [[thread_position_in_grid]]) {
    if (local >= p.count) return;
    uint i = p.start + local;
    float4 a = left[i / p.rightCount], b = right[i % p.rightCount];
    result[i] = !(a.z < b.x || b.z < a.x || a.w < b.y || b.w < a.y);
}
kernel void routingBlend(device const float2* a [[buffer(0)]], device const float2* b [[buffer(1)]], device const float* weights [[buffer(2)]], device float2* result [[buffer(3)]], constant RoutingParameters& p [[buffer(4)]], uint local [[thread_position_in_grid]]) {
    if (local >= p.count) return;
    uint i = p.start + local;
    result[i] = a[i] * (1.0f - weights[i]) + b[i] * weights[i];
}
struct RoutingGrid { int2 origin; uint width; uint rectangles; };
kernel void routingOccupancy(device const int4* rectangles [[buffer(0)]], constant RoutingGrid& grid [[buffer(1)]], device uint* result [[buffer(2)]], constant RoutingParameters& p [[buffer(3)]], uint local [[thread_position_in_grid]]) {
    if (local >= p.count) return;
    uint i = p.start + local;
    int2 c = grid.origin + int2(i % grid.width, i / grid.width);
    uint occupied = 0;
    for (uint j = 0; j < grid.rectangles; ++j) { int4 r = rectangles[j]; if (c.x >= r.x && c.y >= r.y && c.x <= r.z && c.y <= r.w) { occupied = 1; break; } }
    result[i] = occupied;
}
kernel void routingOctilinear(device const float2* a [[buffer(0)]], device const float2* b [[buffer(1)]], device const float* unused [[buffer(2)]], device float2* result [[buffer(3)]], constant RoutingParameters& p [[buffer(4)]], uint local [[thread_position_in_grid]]) {
    if (local >= p.count) return;
    uint i = p.start + local; float2 d = b[i] - a[i]; float diagonal = min(abs(d.x), abs(d.y));
    result[i] = a[i] + float2(d.x >= 0 ? diagonal : -diagonal, d.y >= 0 ? diagonal : -diagonal);
}
kernel void routingParallel(device const float2* a [[buffer(0)]], device const float2* b [[buffer(1)]], device const float* offsets [[buffer(2)]], device float2* result [[buffer(3)]], constant RoutingParameters& p [[buffer(4)]], uint local [[thread_position_in_grid]]) {
    if (local >= p.count) return;
    uint i = p.start + local; float2 d = b[i] - a[i]; float len = max(0.001f, length(d));
    result[i] = (a[i] + b[i]) / 2.0f + float2(-d.y / len, d.x / len) * offsets[i];
}
kernel void routingBusHorizontal(device const float2* a [[buffer(0)]], device const float2* b [[buffer(1)]], device const float* buses [[buffer(2)]], device float2* result [[buffer(3)]], constant RoutingParameters& p [[buffer(4)]], uint local [[thread_position_in_grid]]) {
    if (local >= p.count) return;
    uint i = p.start + local; result[i] = float2(i % 2 == 0 ? a[i].x : b[i].x, buses[i]);
}
kernel void routingBusVertical(device const float2* a [[buffer(0)]], device const float2* b [[buffer(1)]], device const float* buses [[buffer(2)]], device float2* result [[buffer(3)]], constant RoutingParameters& p [[buffer(4)]], uint local [[thread_position_in_grid]]) {
    if (local >= p.count) return;
    uint i = p.start + local; result[i] = float2(buses[i], i % 2 == 0 ? a[i].y : b[i].y);
}
