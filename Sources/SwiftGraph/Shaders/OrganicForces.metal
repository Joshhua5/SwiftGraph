#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)

struct Parameters {
    uint count;
    float temperature;
    float repulsionSquared;
    float attraction;
    uint treeCount;
};

static float2 productionTreeContribution(float2 point, float2 other, float mass, float strength, float2 perturbation) {
    float2 delta = point - other;
    float squared = delta.x * delta.x + delta.y * delta.y;
    if (squared > 250000.0f) return float2(0);
    if (squared < 0.01f) { delta = perturbation; squared = delta.x * delta.x + delta.y * delta.y; }
    return delta * (strength * mass / squared);
}

static float2 productionTreeForce(uint id, float2 point, device const float2 *positions,
    device const float4 *bounds, device const float4 *centers, device const uint4 *children,
    device const uint2 *leaves, device const uint *bodies, float strength, float2 perturbation) {
    // Depth 40, at most three pending siblings per level, plus the active cell.
    uint stack[128]; uint count = 1; stack[0] = 0; float2 force = float2(0);
    while (count > 0) {
        uint index = stack[--count]; float4 cell = centers[index];
        if (cell.z == 0) continue;
        uint4 next = children[index];
        if (next.x == 0xffffffffu) {
            uint2 range = leaves[index];
            for (uint p = range.x; p < range.x + range.y; ++p) {
                uint other = bodies[p];
                if (other != id) force += productionTreeContribution(point, positions[other], 1, strength, perturbation);
            }
        } else {
            float4 rectangle = bounds[index]; float halfSize = rectangle.z / 2;
            float2 offset = point - (rectangle.xy + halfSize);
            float2 near = max(float2(0), abs(offset) - halfSize);
            if (near.x * near.x + near.y * near.y > 250000.0f) continue;
            float2 far = abs(offset) + halfSize, delta = point - cell.xy;
            float distance = delta.x * delta.x + delta.y * delta.y;
            bool contains = point.x >= rectangle.x && point.x <= rectangle.x + rectangle.z
                && point.y >= rectangle.y && point.y <= rectangle.y + rectangle.w;
            if (!contains && far.x * far.x + far.y * far.y <= 250000.0f && rectangle.z * rectangle.z < 0.64f * distance) {
                force += productionTreeContribution(point, cell.xy, cell.z, strength, perturbation);
            } else {
                stack[count++] = next.w; stack[count++] = next.z; stack[count++] = next.y; stack[count++] = next.x;
            }
        }
    }
    return force;
}

// One node per lane. All lanes participate in barriers, including the padded tail.
// Two position buffers prevent threads from reading partially updated coordinates.
kernel void organicStep(
    device const float2* positions [[buffer(0)]],
    device float2* output [[buffer(1)]],
    device const uint* fixed [[buffer(2)]],
    device const uint* offsets [[buffer(3)]],
    device const uint* neighbors [[buffer(4)]],
    constant Parameters& params [[buffer(5)]],
    device const float4* treeBounds [[buffer(6)]],
    device const float4* treeCenters [[buffer(7)]],
    device const uint4* treeChildren [[buffer(8)]],
    device const uint2* treeLeaves [[buffer(9)]],
    device const uint* treeBodies [[buffer(10)]],
    device const float2* perturbations [[buffer(11)]],
    uint id [[thread_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]]) {
    threadgroup float2 tile[128];
    bool active = id < params.count;
    float2 point = active ? positions[id] : float2(0);
    float2 force(0);
    if (params.treeCount > 0) {
        if (!active) return;
        if (fixed[id]) { output[id] = point; return; }
        force = productionTreeForce(id, point, positions, treeBounds, treeCenters, treeChildren, treeLeaves, treeBodies,
            params.repulsionSquared, perturbations[id]);
        for (uint k = offsets[id]; k < offsets[id + 1]; ++k) force += (positions[neighbors[k]] - point) * params.attraction;
        float distance = sqrt(force.x * force.x + force.y * force.y);
        output[id] = distance > 0.1f ? point + force * (min(distance, params.temperature) / distance) : point;
        return;
    }
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

struct BundleParameters {
    uint count;
    uint segments;
    float step;
    uint padding;
};

// Jacobi averaging: all neighbors come from the previous iteration. Duplicate
// adjacency entries retain their CPU weighting; isolated nodes and anchors stay put.
kernel void barycenterStep(
    device const float2* positions [[buffer(0)]],
    device float2* output [[buffer(1)]],
    device const uint* fixed [[buffer(2)]],
    device const uint* offsets [[buffer(3)]],
    device const uint* neighbors [[buffer(4)]],
    constant Parameters& params [[buffer(5)]],
    uint id [[thread_position_in_grid]]) {
    if (id >= params.count) return;
    uint begin = offsets[id], end = offsets[id + 1];
    if (fixed[id] || begin == end) { output[id] = positions[id]; return; }
    float2 sum(0);
    for (uint k = begin; k < end; ++k) sum += positions[neighbors[k]];
    output[id] = sum / float(end - begin);
}
kernel void bundlingStep(
    device const float2* points [[buffer(0)]],
    device float2* output [[buffer(1)]],
    device const uint* offsets [[buffer(2)]],
    device const uint2* compatible [[buffer(3)]],
    device const float* springs [[buffer(4)]],
    constant BundleParameters& params [[buffer(5)]],
    uint id [[thread_position_in_grid]]) {
    if (id >= params.count) return;
    uint stride = params.segments + 1;
    uint edge = id / stride, p = id % stride;
    if (p == 0 || p == params.segments) { output[id] = points[id]; return; }
    float2 force = (points[id - 1] + points[id + 1] - points[id] * 2.0f) * springs[edge];
    for (uint k = offsets[edge]; k < offsets[edge + 1]; ++k) {
        uint2 neighbor = compatible[k];
        uint other = neighbor.x * stride + (neighbor.y ? params.segments - p : p);
        float2 delta = points[other] - points[id];
        force += delta / sqrt(delta.x * delta.x + delta.y * delta.y + 0.0001f);
    }
    output[id] = points[id] + force * params.step;
}

// Error-free sum of two Float values, followed by the residual angle terms.
// Keeping the residual matters for small sectors and pairs crossing 0 / 2*pi.
float2 radialSum(float a, float b) {
    float sum = a + b;
    float part = sum - a;
    return float2(sum, (a - (sum - part)) + (b - part));
}
float radialAngleDistance(float2 a, float2 b) {
    float2 delta = radialSum(a.x, -b.x);
    delta.y += a.y - b.y;
    if (delta.x < 0.0f) delta = -delta;
    if (delta.x > 3.141592653589793f) {
        float2 wrapped = radialSum(6.283185482025146484375f, -delta.x);
        delta = float2(wrapped.x, wrapped.y - 1.748455600074497e-7f - delta.y);
    }
    return abs(delta.x + delta.y);
}
struct RadialParameters { uint start; uint count; };
kernel void radialClearance(device const float2* angles [[buffer(0)]],
                            device const float* diameters [[buffer(1)]],
                            device const uint* ends [[buffer(2)]],
                            device uint* partners [[buffer(3)]],
                            constant RadialParameters& p [[buffer(4)]],
                            uint group [[threadgroup_position_in_grid]],
                            uint lane [[thread_index_in_threadgroup]]) {
    // A group shares one node's search. This exposes parallel work even when a
    // ring has too few nodes to occupy the GPU with one serial search per lane.
    threadgroup float maxima[128];
    threadgroup uint candidates[128];
    uint i = p.start + group, partner = i;
    float maximum = 0.0f;
    for (uint j = i + 1 + lane; j < ends[i]; j += 128) {
        float chord = 2.0f * sin(radialAngleDistance(angles[i], angles[j]) * 0.5f);
        float radius = ((diameters[i] + diameters[j]) * 0.5f + 20.0f) / chord;
        if (radius > maximum) { maximum = radius; partner = j; }
    }
    maxima[lane] = maximum; candidates[lane] = partner;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = 64; stride > 0; stride /= 2) {
        if (lane < stride) {
            float other = maxima[lane + stride];
            uint candidate = candidates[lane + stride];
            if (other > maxima[lane] || (other == maxima[lane] && candidate < candidates[lane])) {
                maxima[lane] = other; candidates[lane] = candidate;
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lane == 0) partners[i] = candidates[0];
}
