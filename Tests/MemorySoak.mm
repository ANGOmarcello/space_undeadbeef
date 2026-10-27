// Created by Angelo Cammalleri on 27.10.2026.
// Paired actual-engine oracle. The uncached switch exists only in headless test
// builds. No guest instructions, health, scenarios or scores are modified.
#include "../Sources/Legacy/SDBEngine.mm"
#import <objc/runtime.h>
#include <mach/mach.h>
#include <cstdio>
#include <chrono>
#include <numeric>

namespace {
constexpr unsigned Warmup = 300, Samples = 1800;
constexpr uint64_t MaximumGrowth = GuestCPU::MemorySize;
unsigned checks = 0;
struct RenderSamples {std::vector<double> cached,uncached;};
bool require(bool value, const char *message) {++checks; if (!value) fprintf(stderr,"FAIL %s\n",message); return value;}
const Runtime *runtime(SDBEngine *engine) {
    Ivar ivar = class_getInstanceVariable(SDBEngine.class,"_runtime");
    if (!ivar) return nullptr;
    const ptrdiff_t offset = ivar_getOffset(ivar);
    if (offset < 0 || size_t(offset) + sizeof(std::unique_ptr<Runtime>) > class_getInstanceSize(SDBEngine.class)) return nullptr;
    const auto *object = static_cast<const uint8_t *>((__bridge const void *)engine);
    return reinterpret_cast<const std::unique_ptr<Runtime> *>(object + offset)->get();
}
uint64_t footprint() {
    task_vm_info_data_t info{}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(),TASK_VM_INFO,reinterpret_cast<task_info_t>(&info),&count)==KERN_SUCCESS ? info.phys_footprint : 0;
}
SDBEngine *makeEngine(NSString *resources,NSString *save,bool uncached) {
    setenv("SDB_SAVE_DIRECTORY",save.UTF8String,1);
    if(uncached)setenv("SDB_TEST_DISABLE_SOFTWARE_MENU_CACHE","1",1);else unsetenv("SDB_TEST_DISABLE_SOFTWARE_MENU_CACHE");
    SDBEngine *engine=[[SDBEngine alloc]initWithResourcePath:resources offersHaptics:YES];
    engine.watchLayout=YES;
    [engine configureViewport:CGSizeMake(416,496) displayScale:1 safeArea:CGRectMake(0,0,416,496)];
    return engine;
}
bool same(SDBEngine *cached,SDBEngine *uncached) {
    if(cached.failure||uncached.failure)fprintf(stderr,"Guest fault: %s / %s\n",cached.failure.UTF8String?:"none",uncached.failure.UTF8String?:"none");
    if(!require(!cached.failure&&!uncached.failure,"paired engines remain healthy"))return false;
    const Runtime *a=runtime(cached),*b=runtime(uncached);
    if(!require(a&&b,"read-only runtime inspection available"))return false;
    if(!require(a->cpu.r==b->cpu.r&&a->cpu.n==b->cpu.n&&a->cpu.z==b->cpu.z&&a->cpu.c==b->cpu.c&&
                a->cpu.v==b->cpu.v&&a->cpu.thumb==b->cpu.thumb&&a->cpu.instructionCount==b->cpu.instructionCount,
                "exact guest registers flags and instruction counts")||
       !require(a->cpu.memory==b->cpu.memory,"all32MiB of guest memory match")||
       !require(a->allocations==b->allocations&&a->freeBlocks==b->freeBlocks&&a->heap==b->heap&&a->seed==b->seed,
                "allocator and RNG state match")||
       !require(a->frames==b->frames&&a->draws==b->draws&&a->audioEvents==b->audioEvents,"frame draw and audio counters match")||
       !require(a->texture==b->texture&&a->textured==b->textured&&a->blend==b->blend&&a->textureEnv==b->textureEnv&&
                a->sourceBlend==b->sourceBlend&&a->destBlend==b->destBlend&&a->matrix.m==b->matrix.m,
                "final original graphics state restored")||
       !require(a->pixels==b->pixels,"actual software frame bytes match exactly")||
       !require([cached consumeHapticEvents]==[uncached consumeHapticEvents],"original feedback events match"))return false;
    return true;
}
bool step(SDBEngine *a,SDBEngine *b,RenderSamples *samples=nullptr) {
    using Clock=std::chrono::steady_clock;
    [a advanceSimulation:1.0/60];[b advanceSimulation:1.0/60];
    const auto render=[](SDBEngine *engine) {const auto start=Clock::now();[engine renderFrame];
        return std::chrono::duration<double,std::milli>(Clock::now()-start).count();};
    double cached=0,uncached=0;
    if(samples&&samples->cached.size()%2) {uncached=render(b);cached=render(a);}
    else {cached=render(a);uncached=render(b);}
    if(samples) {samples->cached.push_back(cached);samples->uncached.push_back(uncached);}
    return same(a,b);
}
bool activate(SDBEngine *engine,NSString *label) {
    for(SDBMenuAction *action in engine.menuActions)if([action.label isEqual:label])return [engine activateMenuAction:action.identifier];
    fprintf(stderr,"Missing action %s\n",label.UTF8String);return false;
}
bool both(SDBEngine *a,SDBEngine *b,NSString *label) {return require(activate(a,label)&&activate(b,label),"same original menu decision accepted");}
}

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if(argc!=3)return 64;
        setenv("SDB_MUTE_AUDIO","1",1);setenv("SDB_CPU_RENDERER","1",1);
        NSString *resources=[NSString stringWithUTF8String:argv[1]],*root=[NSString stringWithUTF8String:argv[2]];
        NSString *cachedPath=[root stringByAppendingPathComponent:@"cached"],*uncachedPath=[root stringByAppendingPathComponent:@"uncached"];
        SDBEngine *cached=makeEngine(resources,cachedPath,false),*uncached=makeEngine(resources,uncachedPath,true);
        if(!same(cached,uncached))return 1;
        for(unsigned index=0;index<Warmup;++index)if(!step(cached,uncached))return 1;
        const uint64_t baseline=footprint();uint64_t peak=baseline;
        RenderSamples renderSamples;renderSamples.cached.reserve(Samples);renderSamples.uncached.reserve(Samples);
        unsigned hits=0,changes=0;
        for(unsigned index=0;index<Samples;++index) {
            @autoreleasepool {
                if(index==Samples/2&&!both(cached,uncached,@"Options"))return 1;
                if(index==Samples*5/6&&!both(cached,uncached,@"Sound Off"))return 1;
                CGImageRef previous=cached.frame;
                if(!step(cached,uncached,&renderSamples))return 1;
                if(previous==cached.frame)++hits;else ++changes;
                if(index%60==0)peak=std::max(peak,footprint());
            }
        }
        if(!require(hits>Samples/2&&changes>0,"settled menus reuse image identity while transitions still change")||
           !require(baseline&&peak<=baseline+MaximumGrowth,"post-warm process footprint growth remains bounded"))return 1;
        CGImageRef beforeResize=cached.frame;
        [cached configureViewport:CGSizeMake(480,480) displayScale:1 safeArea:CGRectMake(0,0,480,480)];
        [uncached configureViewport:CGSizeMake(480,480) displayScale:1 safeArea:CGRectMake(0,0,480,480)];
        if(!require(cached.frame!=beforeResize,"resize invalidates reused frame")||!same(cached,uncached)||
           !both(cached,uncached,@"Save and Exit"))return 1;
        for(unsigned index=0;index<120;++index)if(!step(cached,uncached))return 1;
        if(!both(cached,uncached,@"Game Start"))return 1;
        for(unsigned index=0;index<120;++index)if(!step(cached,uncached))return 1;
        if(!require(cached.gameMenuType==0,"ordinary gameplay reached"))return 1;
        for(unsigned index=0;index<16;++index) {
            CGImageRef previous=cached.frame;
            if(!step(cached,uncached)||!require(cached.frame!=previous,"gameplay publishes every rendered frame"))return 1;
        }
        [cached setSuspended:YES];[uncached setSuspended:YES];
        CGImageRef retained=CGImageRetain(cached.frame);
        [cached trimTransientResources];[uncached trimTransientResources];
        if(!require(cached.frame==retained,"inactive trim preserves visible immutable frame"))return 1;
        CGImageRelease(retained);
        [cached setSuspended:NO];[uncached setSuspended:NO];
        if(!step(cached,uncached))return 1;
        if(!require([cached saveProgress]&&[uncached saveProgress],"paired saves complete"))return 1;
        NSData *a=[NSData dataWithContentsOfFile:[cachedPath stringByAppendingPathComponent:@"savedata.dat"]];
        NSData *b=[NSData dataWithContentsOfFile:[uncachedPath stringByAppendingPathComponent:@"savedata.dat"]];
        if(!require(a.length==256&&[a isEqual:b],"original saved bytes match after trim/resume"))return 1;
        [cached setSuspended:YES];[uncached setSuspended:YES];
        printf("Passed %u software menu/soak checks; samples=%u warmup=%u reused=%u changed=%u footprintBaseline=%llu peak=%llu growthLimit=%llu bytes.\n",
            checks,Samples,Warmup,hits,changes,(unsigned long long)baseline,(unsigned long long)peak,(unsigned long long)MaximumGrowth);
        printf("Native Mac process proxy; no physical Watch battery or memory claim.\n");
        for(auto entry:{std::make_pair("cached",renderSamples.cached),std::make_pair("uncached",renderSamples.uncached)}) {
            std::sort(entry.second.begin(),entry.second.end());
            printf("menuRenderCPU %s n=%zu mean=%.3f p99=%.3f ms; simulation and oracle comparisons excluded.\n",entry.first,
                entry.second.size(),std::accumulate(entry.second.begin(),entry.second.end(),0.0)/entry.second.size(),
                entry.second[size_t(std::ceil(entry.second.size()*.99))-1]);
        }
    }
}
