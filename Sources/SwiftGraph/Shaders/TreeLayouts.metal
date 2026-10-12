#include <metal_stdlib>
using namespace metal;
struct Parameters { uint count, orderCount, mode, stage, start, end, padding0, padding1; };
float2 center(float4 r) { return r.xy+r.zw/2; }
kernel void orderedPlacement(device const float4* input [[buffer(0)]], device float4* output [[buffer(1)]],
    device const uint* flags [[buffer(2)]], device const int4* records [[buffer(3)]],
    device const uint* order [[buffer(4)]], device const uint* offsets [[buffer(5)]],
    device const uint* children [[buffer(6)]], device const float* s [[buffer(7)]],
    device float4* scratch [[buffer(8)]], constant Parameters& p [[buffer(9)]], uint tid [[thread_position_in_grid]]) {
    if(tid!=0) return;
    if(p.stage==0) scratch[p.count]=float4(0);
    if(p.mode==0) {
        float cursor=scratch[p.count].x;
        for(uint k=p.start;k<p.end;k++) {
            uint i=order[k]; int depth=records[i].x; float y=0;
            for(int d=0;d<depth;d++) {
                float height=0; for(uint j=0;j<p.count;j++) if(records[j].x==d && (flags[j]&8)!=0) height=max(height,input[j].w);
                y+=height+s[1];
            }
            output[i].y=y;
            if(offsets[i+1]>offsets[i]) {
                uint first=children[offsets[i]],last=children[offsets[i+1]-1];
                output[i].x=(center(output[first]).x+center(output[last]).x)/2-output[i].z/2;
                cursor=max(cursor,output[i].x+output[i].z+s[0]);
            } else { output[i].x=cursor; cursor+=output[i].z+s[0]; }
            if(records[i].z==1) cursor+=2*s[0];
        }
        scratch[p.count].x=cursor;
    } else if(p.mode==1) {
        if(p.stage==0) {
            for(uint k=p.orderCount;k>0;k--) {
                uint i=order[k-1]; float weight=1;
                for(uint j=offsets[i];j<offsets[i+1];j++) weight+=scratch[children[j]].x;
                scratch[i]=float4(weight,0,0,0);
            }
            return;
        }
        float cursor=scratch[p.count].x;
        for(uint k=p.start;k<p.end;k++) {
            uint i=order[k];
            if(records[i].y<0) { output[i].xy=0; scratch[i].y=0; scratch[i].z=2*M_PI_F; }
            uint count=offsets[i+1]-offsets[i];
            if(count>0) {
                float total=0,span=0;
                for(uint j=offsets[i];j<offsets[i+1];j++) {
                    uint child=children[j]; total+=scratch[child].x; span=max(span,length(output[child].zw));
                }
                span+=20; float sweep=scratch[i].z,radius=max(s[0],float(count)*span/max(sweep,1e-9f)),angle=scratch[i].y;
                for(uint j=offsets[i];j<offsets[i+1];j++) {
                    uint child=children[j]; float childSweep=sweep*scratch[child].x/total,mid=angle+childSweep/2;
                    output[child].xy=center(output[i])+radius*float2(cos(mid),sin(mid))-output[child].zw/2;
                    scratch[child].y=angle; scratch[child].z=childSweep; angle+=childSweep;
                }
            }
            if(k+1==p.orderCount || records[order[k+1]].z!=records[i].z) {
                uint begin=k; while(begin>0 && records[order[begin-1]].z==records[i].z) begin--;
                float left=INFINITY,right=-INFINITY;
                for(uint j=begin;j<=k;j++) { float4 r=output[order[j]];left=min(left,r.x);right=max(right,r.x+r.z); }
                if(records[i].z>0) for(uint j=begin;j<=k;j++) output[order[j]].x+=cursor-left;
                cursor=records[i].z==0?right+s[0]:cursor+right-left+s[0];
            }
        }
        scratch[p.count].x=cursor;
    } else if(p.mode==2) {
        float cursor=scratch[p.count].x;
        for(uint k=p.start;k<p.end;k++) {
            uint i=order[k],first=p.count,last=p.count;
            for(uint j=offsets[i];j<offsets[i+1];j++) if((flags[children[j]]&2)==0) {
                if(first==p.count) first=children[j]; last=children[j];
            }
            output[i].y=float(records[i].x)*s[0];
            if(first!=p.count) output[i].x=(center(output[first]).x+center(output[last]).x)/2-output[i].z/2;
            else { output[i].x=cursor; cursor+=output[i].z; }
            cursor=max(cursor,output[i].x+output[i].z); float assistantY=output[i].y+20;
            for(uint j=offsets[i];j<offsets[i+1];j++) {
                uint child=children[j]; if((flags[child]&2)==0) continue;
                output[child].xy=float2(output[i].x+output[i].z+20,assistantY);
                assistantY+=output[child].w+10;cursor=max(cursor,output[child].x+output[child].z);
            }
            cursor+=s[1];
        }
        scratch[p.count].x=cursor;
    } else if(p.mode==3) {
        if(p.stage==0) {
        for(uint k=p.orderCount;k>0;k--) {
            uint i=order[k-1]; float weight=0;
            for(uint j=offsets[i];j<offsets[i+1];j++) weight+=scratch[children[j]].x;
            scratch[i].x=max(1.0f,weight);
        }
        return;
        }
        for(uint k=p.start;k<p.end;k++) {
            uint i=order[k]; if(records[i].z==1) output[i]=float4(0,0,1000,1000);
            float4 r=output[i]; bool vertical=r.z>r.w;
            float4 inner=float4(r.xy+s[0],max(float2(0),r.zw-2*s[0])); float position=vertical?inner.x:inner.y,total=0;
            for(uint j=offsets[i];j<offsets[i+1];j++) total+=scratch[children[j]].x;
            total=max(1.0f,total);
            for(uint j=offsets[i];j<offsets[i+1];j++) {
                uint child=children[j];float ratio=scratch[child].x/total;
                if(vertical) { output[child]=float4(position,inner.y,inner.z*ratio,inner.w);position+=inner.z*ratio; }
                else { output[child]=float4(inner.x,position,inner.z,inner.w*ratio);position+=inner.w*ratio; }
            }
        }
    }
}
