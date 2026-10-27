// Created by Angelo Cammalleri on 27.10.2026.
// Checkpoint fixtures enter only through original SaveData loading and Continue.
#include "../Sources/Legacy/SDBEngine.mm"
#import <objc/runtime.h>
#include <cstdio>

namespace {
constexpr uint32_t Checkpoints[] = {0,4,8,12,17,23,27,31,36,47,52,58,62,66,70,77,85};
constexpr unsigned TitleFrames = 120, ResumeFrames = 240;
unsigned checks = 0;
bool require(bool value,const char *message) {++checks;if(!value)fprintf(stderr,"FAIL %s\n",message);return value;}
void put(NSMutableData *data,size_t offset,uint32_t value) {
    auto *bytes=static_cast<uint8_t *>(data.mutableBytes);
    for(unsigned i=0;i<4;++i)bytes[offset+i]=uint8_t(value>>(i*8));
}
Runtime *runtime(SDBEngine *engine) {
    Ivar ivar=class_getInstanceVariable(SDBEngine.class,"_runtime");
    if(!ivar)return nullptr;
    const ptrdiff_t offset=ivar_getOffset(ivar);
    if(offset<0||size_t(offset)+sizeof(std::unique_ptr<Runtime>)>class_getInstanceSize(SDBEngine.class))return nullptr;
    auto *object=static_cast<uint8_t *>((__bridge void *)engine);
    return reinterpret_cast<std::unique_ptr<Runtime> *>(object+offset)->get();
}
bool advance(SDBEngine *engine,unsigned count) {
    for(unsigned index=0;index<count;++index) {
        [engine advanceSimulation:1.0/60];
        if(engine.failure) {fprintf(stderr,"Guest fault: %s\n",engine.failure.UTF8String);return false;}
    }
    return true;
}
struct Observed {uint64_t resume=0,scenario=0,zako=0,corporal=0,sergeant=0,snake=0;};
}

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if(argc!=3)return 64;
        setenv("SDB_MUTE_AUDIO","1",1);setenv("SDB_CPU_RENDERER","1",1);
        NSString *resources=[NSString stringWithUTF8String:argv[1]],*root=[NSString stringWithUTF8String:argv[2]];
        NSString *basePath=[root stringByAppendingPathComponent:@"base"];
        setenv("SDB_SAVE_DIRECTORY",basePath.UTF8String,1);
        SDBEngine *baseEngine=[[SDBEngine alloc]initWithResourcePath:resources];
        NSData *base=[baseEngine.progressPortableSnapshot[@"saveData"] copy];
        if(!require(base.length==256&&[SDBSaveStore isValidOriginalData:base],"fixture starts with actual original packed record"))return 1;
        [baseEngine setSuspended:YES];baseEngine=nil;
        Observed total;
        for(size_t index=0;index<std::size(Checkpoints);++index) {
            @autoreleasepool {
                const uint32_t cursor=Checkpoints[index],lap=cursor==85?1:0,counter=cursor==85?0:uint32_t(index);
                NSMutableData *fixture=[base mutableCopy];
                // Test save fixtures only: never write live guest memory.
                put(fixture,0x20,0);put(fixture,0x24,0);put(fixture,0x28,0);
                put(fixture,0x2c,cursor);put(fixture,0x30,counter);put(fixture,0x34,lap);put(fixture,0x38,0);
                NSDictionary *portable=[SDBSaveStore portableSnapshotForData:fixture];
                if(!require(portable&&[[SDBSaveStore dataFromPortableSnapshot:portable]isEqual:fixture],"checkpoint fixture passes original and portable validators"))return 1;
                NSString *path=[root stringByAppendingPathComponent:[NSString stringWithFormat:@"checkpoint-%u",cursor]];
                SDBSaveStore *store=[[SDBSaveStore alloc]initWithDirectory:path];
                if(!require([store writeData:fixture],"isolated fixture stored with verified integrity record"))return 1;
                setenv("SDB_SAVE_DIRECTORY",path.UTF8String,1);
                SDBEngine *engine=[[SDBEngine alloc]initWithResourcePath:resources];
                if(!require(advance(engine,TitleFrames)&&engine.gameMenuType==1,"original loader reaches healthy title"))return 1;
                NSDictionary *loaded=engine.progressPortableSnapshot;
                if(!require([loaded[@"lap"]unsignedIntValue]==lap&&[loaded[@"checkpoint"]unsignedIntValue]==counter&&
                    [loaded[@"saveData"]isEqual:fixture],"original load and pack retain exact checkpoint fixture"))return 1;
                Runtime *r=runtime(engine);
                if(!require(r!=nullptr,"read-only execution observer available"))return 1;
                Observed observed;
                const auto previousHook=r->cpu.hook;
                r->cpu.hook=[previousHook,&observed](GuestCPU &cpu,uint32_t pc) {
                    // Observe symbol entry only, preserving the original hook
                    // result and every instruction, register and memory write.
                    switch(pc) {
                        case 0x52a0:++observed.resume;break;
                        case 0x89d0:++observed.scenario;break;
                        case 0xbfa8:++observed.zako;break;
                        case 0xe0a4:++observed.corporal;break;
                        case 0xbbd8:++observed.sergeant;break;
                        case 0xc85c:++observed.snake;break;
                    }
                    return previousHook(cpu,pc);
                };
                SDBMenuAction *continuation=nil;
                for(SDBMenuAction *action in engine.menuActions)if([action.label isEqual:@"Continue"])continuation=action;
                if(!require(continuation&&[engine activateMenuAction:continuation.identifier],"original Continue decision accepted")||
                   !require(advance(engine,ResumeFrames),"240 normal fixed steps remain healthy"))return 1;
                [engine renderFrame];
                if(!require(!engine.failure&&engine.frame&&observed.resume==1&&observed.scenario>0,
                    "original continue/scenario execution produces a frame without guest faults")||
                   !require(engine.gameMenuType==0||engine.gameMenuType==2,"ordinary gameplay or natural game-over menu remains valid")||
                   !require([engine saveProgress]&&!engine.lastSaveError,"resumed original progress saves successfully"))return 1;
                NSData *saved=[NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:@"savedata.dat"]];
                if(!require([SDBSaveStore isValidOriginalData:saved]&&[SDBSaveStore portableSnapshotForData:saved],"resumed checkpoint produces valid original portable record"))return 1;
                printf("checkpoint cursor=%u lap=%u counter=%u frames=%u menu=%ld scenarioCalls=%llu enemyConstructors=%llu/%llu/%llu/%llu\n",
                    cursor,lap,counter,ResumeFrames,long(engine.gameMenuType),(unsigned long long)observed.scenario,
                    (unsigned long long)observed.zako,(unsigned long long)observed.corporal,
                    (unsigned long long)observed.sergeant,(unsigned long long)observed.snake);
                r->cpu.hook=previousHook;
                total.resume+=observed.resume;total.scenario+=observed.scenario;total.zako+=observed.zako;
                total.corporal+=observed.corporal;total.sergeant+=observed.sergeant;total.snake+=observed.snake;
                [engine setSuspended:YES];
            }
        }
        if(!require(total.resume==std::size(Checkpoints)&&total.corporal>0&&total.sergeant>0,
            "all original resumes plus naturally reached Corporal and Sergeant constructors execute"))return 1;
        printf("Passed %u checkpoint resume checks across %zu exact original checkpoint entries; each runs %u normal steps.\n",
            checks,std::size(Checkpoints),ResumeFrames);
        printf("Observed original constructors: Zako=%llu Corporal=%llu Sergeant=%llu Snake=%llu; checkpoint-entry smoke, not full-stage completion.\n",
            (unsigned long long)total.zako,(unsigned long long)total.corporal,(unsigned long long)total.sergeant,(unsigned long long)total.snake);
    }
}
