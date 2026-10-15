#include <metal_stdlib>
using namespace metal;
struct Parameters { uint count, orderCount, mode, stage, start, end, padding0, padding1; };
float2 center(float4 r) { return r.xy + r.zw * 0.5f; }
bool intersects(float4 a, float4 b) { return a.x < b.x+b.z && a.x+a.z > b.x && a.y < b.y+b.w && a.y+a.w > b.y; }
float4 inflate(float4 a, float gap) { return float4(a.xy-gap, a.zw+2*gap); }

kernel void basicPlacement(device const float4* input [[buffer(0)]], device float4* output [[buffer(1)]],
    device const uint* flags [[buffer(2)]], device const int4* records [[buffer(3)]],
    device const uint* order [[buffer(4)]], device const uint* offsets [[buffer(5)]],
    device const uint* children [[buffer(6)]], device const float* s [[buffer(7)]],
    device float4* scratch [[buffer(8)]], constant Parameters& p [[buffer(9)]], uint t [[thread_position_in_grid]]) {
    if(t>=p.orderCount) return;
    uint i=order[t]; float4 r=input[i]; float2 position=r.xy;
    if(p.mode==0) {
        float radius=s[0];
        float angle=s[1+t];
        position=float2(radius+50)+radius*float2(cos(angle),sin(angle))-r.zw/2;
    } else if(p.mode==1) {
        float2 step=0; for(uint k=0;k<p.orderCount;k++) step=max(step,input[order[k]].zw);
        step+=s[0]; uint columns=max(1u,uint(s[1])); position=float2(t%columns,t/columns)*step;
    } else if(p.mode==2 || p.mode==3) {
        int row=records[i].x,col=records[i].y; float x=0,y=0,w=0,h=0;
        for(int c=0;c<=col;c++) {
            float size=p.mode==2?s[0]:0;
            for(uint k=0;k<p.orderCount;k++) if(records[order[k]].y==c) size=max(size,input[order[k]].z+(p.mode==2?2*s[2]:0));
            if(c<col) x+=size+(p.mode==3?s[0]:0); else w=size;
        }
        for(int a=0;a<=row;a++) {
            float size=p.mode==2?s[1]:0;
            for(uint k=0;k<p.orderCount;k++) if(records[order[k]].x==a) size=max(size,input[order[k]].w+(p.mode==2?2*s[2]:0));
            if(a<row) y+=size+(p.mode==3?s[0]:0); else h=size;
        }
        position=float2(x+w/2,y+h/2)-r.zw/2;
    } else if(p.mode==4) {
        uint largest=max(1u,p.orderCount/2); float c=0;
        for(uint k=0;k<largest;k++) c+=max(input[order[k]].z,input[order[k]].w);
        c=c/float(largest)/2+s[0]; float radius=c*sqrt(float(t));
        // Split the golden angle and recover multiplication rounding with FMA.
        // A single Float angle accumulates visible phase error on larger disks.
        float high=float(t)*2.399963140487671f;
        float low=fma(float(t),2.399963140487671f,-high)+float(t)*8.92409826e-8f;
        float sh=sin(high),ch=cos(high),sl=sin(low),cl=cos(low);
        position=radius*float2(ch*cl-sh*sl,sh*cl+ch*sl)-r.zw/2;
    } else if(p.mode==5) {
        uint cols=uint(s[4]); float cw=s[2]>0?s[2]/s[4]:1, ch=s[3]>0?s[3]/s[5]:1;
        position=float2(s[0]+(float(t%cols)+0.5f)*cw,s[1]+(float(t/cols)+0.5f)*ch)-r.zw/2;
    } else if(p.mode==6) {
        float width=0,y=s[2];
        for(uint k=0;k<p.count;k++) width=max(width,input[k].z);
        for(uint k=0;k<t;k++) y+=input[order[k]].w+s[0];
        r.z=width; position=float2(s[1],y);
    } else if(p.mode==7) {
        float2 low=float2(INFINITY),high=float2(-INFINITY);
        for(uint k=0;k<p.count;k++) { low=min(low,input[k].xy); high=max(high,input[k].xy+input[k].zw); }
        int horizontal=records[i].x,vertical=records[i].y;
        if(horizontal==1) position.x=low.x;
        else if(horizontal==2) position.x=(low.x+high.x)/2-r.z/2;
        else if(horizontal==3) position.x=high.x-r.z;
        else if(horizontal==7 && s[0]>0) position.x=rint(position.x/s[0])*s[0];
        if(vertical==4) position.y=low.y;
        else if(vertical==5) position.y=(low.y+high.y)/2-r.w/2;
        else if(vertical==6) position.y=high.y-r.w;
        else if(vertical==7 && s[0]>0) position.y=rint(position.y/s[0])*s[0];
    }
    output[i]=float4(position,r.zw);
}
void stableSort(device uint* indices, uint count, device float4* positions, bool horizontal, bool byCenter) {
    for(uint i=1;i<count;i++) {
        uint value=indices[i],j=i;
        float key=horizontal?positions[value].x:positions[value].y;
        if(byCenter) key+=(horizontal?positions[value].z:positions[value].w)/2;
        while(j>0) {
            uint prior=indices[j-1]; float a=horizontal?positions[prior].x:positions[prior].y;
            if(byCenter) a+=(horizontal?positions[prior].z:positions[prior].w)/2;
            if(a<key || (a==key && prior<value)) break;
            indices[j]=prior;j--;
        }
        indices[j]=value;
    }
}
kernel void orderedPlacement(device const float4* input [[buffer(0)]], device float4* output [[buffer(1)]],
    device const uint* flags [[buffer(2)]], device const int4* records [[buffer(3)]],
    device const uint* order [[buffer(4)]], device const uint* offsets [[buffer(5)]],
    device const uint* children [[buffer(6)]], device const float* s [[buffer(7)]],
    device float4* scratch [[buffer(8)]], constant Parameters& p [[buffer(9)]], uint tid [[thread_position_in_grid]]) {
    if(tid!=0) return;
    if(p.mode==10 || p.mode==11) {
        uint nodeCount=uint(s[4]);
        if(p.stage==0) {
            scratch[p.count]=float4(0);
            if(p.mode==10) {
                int lastRank=0;for(uint i=0;i<nodeCount;i++) lastRank=max(lastRank,records[i].x);
                float y=0;
                for(int rank=0;rank<=lastRank;rank++) {
                    float height=0;for(uint i=0;i<nodeCount;i++) if(records[i].x==rank) height=max(height,input[i].w);
                    scratch[rank].x=y;y+=height+s[3];
                }
            }
            return;
        }
        float x=scratch[p.count].x;
        for(uint t=p.start;t<p.end;t++) {
            uint lane=order[t]; float width=0,bottom=0;float2 low=float2(INFINITY),high=float2(-INFINITY);
            for(uint j=offsets[lane];j<offsets[lane+1];j++) {
                uint i=children[j];width=max(width,input[i].z);low=min(low,input[i].xy);high=max(high,input[i].xy+input[i].zw);
            }
            float effectiveWidth=max(s[0],(p.mode==10?width:high.x-low.x)+2*s[2]);
            output[lane]=float4(x,0,effectiveWidth,0);
            for(uint j=offsets[lane];j<offsets[lane+1];j++) {
                uint i=children[j];
                if(p.mode==10) {
                    output[i].y=max(bottom,scratch[records[i].x].x+s[2]);
                    output[i].x=x+(effectiveWidth-input[i].z)/2;bottom=output[i].y+input[i].w+s[3];
                } else {
                    output[i].xy=input[i].xy-low+float2(x+(effectiveWidth-(high.x-low.x))/2,s[2]);
                }
            }
            x+=effectiveWidth+s[1];
        }
        scratch[p.count].x=x;return;
    }
    if(p.mode==8) {
        float4 area=float4(s[0],s[1],s[2],s[3]); const float gap=10;
        for(uint t=p.start;t<p.end;t++) {
            uint i=order[t]; float4 start=output[i]; if(!intersects(start,area)) continue;
            float2 best=0; float distance=INFINITY;
            for(uint side=0;side<4;side++) {
                float2 move= side==0?float2(area.x-start.x-start.z-gap,0):side==1?float2(area.x+area.z-start.x+gap,0):
                             side==2?float2(0,area.y-start.y-start.w-gap):float2(0,area.y+area.w-start.y+gap);
                if((flags[i]&1)==0) for(uint step=0;step<=p.count;step++) {
                    uint hit=p.count;
                    for(uint k=0;k<p.count;k++) if(k!=i && (flags[k]&1)==0 && intersects(inflate(float4(start.xy+move,start.zw),gap-1e-6f),output[k])) { hit=k; break; }
                    if(hit==p.count) break;
                    float4 other=output[hit];
                    if(side==0) move.x=other.x-gap-start.x-start.z;
                    else if(side==1) move.x=other.x+other.z+gap-start.x;
                    else if(side==2) move.y=other.y-gap-start.y-start.w;
                    else move.y=other.y+other.w+gap-start.y;
                }
                float d=abs(move.x)+abs(move.y); if(d<distance) { distance=d; best=move; }
            }
            output[i].xy+=best;
        }
        return;
    }
    // Ordered passes are split into commands. Scratch order/windows persist until
    // each stage finishes, retaining Gauss-Seidel semantics across submissions.
    device uint* indices=reinterpret_cast<device uint*>(scratch+p.count*2+1);
    float spacing=s[0];
    if(p.stage==0 || p.stage==2) {
        bool horizontal=p.stage==0;
        for(uint k=0;k<p.orderCount;k++) indices[k]=order[k];
        stableSort(indices,p.orderCount,output,horizontal,true);
        for(uint k=0;k<p.orderCount;k++) scratch[k]=float4(center(output[indices[k]]),0,0);
        return;
    }
    if(p.stage==1 || p.stage==3) {
        bool horizontal=p.stage==1;
        for(uint t=p.start;t<p.end;t++) {
            float key=horizontal?scratch[t].x:scratch[t].y;
            if(t>0 && (horizontal?scratch[t-1].x:scratch[t-1].y)==key) continue;
            uint end=t;
            while(end+1<p.orderCount && (horizontal?scratch[end+1].x:scratch[end+1].y)==key) end++;
            float shift=0;
            for(uint a=t;a<=end;a++) for(uint b=end+1;b<p.orderCount;b++) {
                float4 ra=output[indices[a]],rb=output[indices[b]]; float2 delta=center(rb)-center(ra),need=(ra.zw+rb.zw)/2+spacing;
                if(abs(delta.x)<need.x-1e-9f && abs(delta.y)<need.y-1e-9f) {
                    float scale=min(delta.x!=0?need.x/abs(delta.x):INFINITY,delta.y!=0?need.y/abs(delta.y):INFINITY);
                    shift=max(shift,(horizontal?delta.x:delta.y)*(scale-1));
                }
            }
            if(shift>0) for(uint b=end+1;b<p.orderCount;b++) { if(horizontal) output[indices[b]].x+=shift; else output[indices[b]].y+=shift; }
        }
        return;
    }
    if(p.stage==4) {
        for(uint k=0;k<p.orderCount;k++) indices[k]=order[k];
        stableSort(indices,p.orderCount,output,true,false);
        for(uint k=0;k<p.orderCount;k++) scratch[k]=float4(output[indices[k]].x,output[indices[k]].x+output[indices[k]].z,0,0);
        scratch[p.count].x=0; return;
    }
    if(p.stage==5) {
        for(uint a=p.start;a<p.end;a++) for(uint b=a+1;b<p.orderCount;b++) {
            if(scratch[b].x>=scratch[a].y+spacing) break;
            uint i=indices[a],j=indices[b]; float4 ra=output[i],rb=output[j];
            float2 need=min(ra.xy+ra.zw,rb.xy+rb.zw)-max(ra.xy,rb.xy)+spacing;
            if(need.x<=1e-9f || need.y<=1e-9f) continue;
            bool horizontal=need.x<=need.y; float2 ca=center(ra),cb=center(rb);
            bool forward=horizontal?(ca.x==cb.x?i<j:ca.x<cb.x):(ca.y==cb.y?i<j:ca.y<cb.y);
            float step=(horizontal?need.x:need.y)/2*(forward?1:-1);
            if(horizontal) { output[i].x-=step; output[j].x+=step; } else { output[i].y-=step; output[j].y+=step; }
            scratch[p.count].x=1;
        }
        return;
    }
    if(p.stage==6) {
        for(uint i=0;i<p.count;i++) indices[i]=i;
        stableSort(indices,p.count,output,true,false); return;
    }
    // Same terminating sweep as CPU, including groups only in this final stage.
    for(uint t=p.start;t<p.end;t++) {
        uint i=indices[t]; stableSort(indices,t,output,true,false);
        for(uint b=0;b<t;b++) {
            float4 a=output[i],r=output[indices[b]];
            if(a.y<r.y+r.w+spacing && a.y+a.w+spacing>r.y && a.x<r.x+r.z+spacing && a.x+a.z>r.x) output[i].x=r.x+r.z+spacing;
        }
    }
}
