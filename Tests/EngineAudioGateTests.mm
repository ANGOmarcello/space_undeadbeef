// Created by Angelo Cammalleri on 27.10.2026.
// Actual original menus and audio bridges with an injected native transport.
// No output device, recording session or real user preferences are accessed.
#include "../Sources/Legacy/SDBEngine.mm"
#import <objc/runtime.h>
#include <cstdio>

@class GateAudioMixer;
@interface GateAudioVoice : NSObject
@property(nonatomic, weak) GateAudioMixer *mixer;
@property(nonatomic) BOOL playing;
@property(nonatomic) BOOL failPlay;
@property(nonatomic) float volume;
@property(nonatomic) NSInteger numberOfLoops;
@property(nonatomic) unsigned playCount;
@property(nonatomic) unsigned configureCount;
- (BOOL)isPlaying;
- (BOOL)configureBuffer:(uint32_t)identifier loop:(BOOL)loop;
- (BOOL)play;
- (void)pause;
- (void)stop;
@end

@interface GateAudioMixer : NSObject
@property(nonatomic) NSString *failure;
@property(nonatomic) float outputVolume;
@property(nonatomic) BOOL prepared;
@property(nonatomic) unsigned startFailures;
@property(nonatomic) unsigned rebuildFailures;
@property(nonatomic) unsigned prepareCount;
@property(nonatomic) unsigned rebuildCount;
@property(nonatomic) unsigned loadCount;
@property(nonatomic) NSArray<GateAudioVoice *> *voices;
- (BOOL)loadBuffer:(uint32_t)identifier URL:(NSURL *)url;
- (BOOL)prepare;
- (void)suspend;
- (BOOL)rebuildAfterMediaServicesReset;
- (void)wakeIfNeeded;
- (SDBAudioVoice *)voiceForSource:(uint32_t)source;
@end

@implementation GateAudioVoice
- (BOOL)isPlaying {return _playing;}
- (BOOL)configureBuffer:(uint32_t)identifier loop:(BOOL)loop {
    if (!identifier || identifier>12) return NO;
    ++_configureCount;_numberOfLoops=loop?-1:0;_playing=NO;return YES;
}
- (BOOL)play {
    if (!_mixer.prepared || _failPlay) {_failPlay=NO;return NO;}
    ++_playCount;_playing=YES;return YES;
}
- (void)pause {_playing=NO;}
- (void)stop {_playing=NO;}
@end

@implementation GateAudioMixer
- (instancetype)init {
    if ((self=[super init])) {
        NSMutableArray *voices=[NSMutableArray array];
        for (unsigned index=0;index<9;++index) {
            GateAudioVoice *voice=[GateAudioVoice new];voice.mixer=self;[voices addObject:voice];
        }
        _voices=[voices copy];
    }
    return self;
}
- (BOOL)loadBuffer:(uint32_t)identifier URL:(NSURL *)url {
    if (!identifier || identifier>12 || !url.isFileURL) return NO;
    ++_loadCount;return YES;
}
- (BOOL)prepare {
    ++_prepareCount;
    if (_failure) return NO;
    if (_startFailures) {--_startFailures;_failure=@"Simulated busy audio output";return NO;}
    _prepared=YES;return YES;
}
- (void)suspend {_prepared=NO;}
- (BOOL)rebuildAfterMediaServicesReset {
    ++_rebuildCount;_prepared=NO;
    if (_rebuildFailures) {--_rebuildFailures;_failure=@"Simulated native graph failure";return NO;}
    _failure=nil;return YES;
}
- (void)wakeIfNeeded {}
- (SDBAudioVoice *)voiceForSource:(uint32_t)source {
    return source && source<=_voices.count ? (SDBAudioVoice *)_voices[source-1] : nil;
}
@end

@interface SDBEngine (AudioGateSeams)
- (SDBAudioMixer *)newAudioMixer;
- (BOOL)activateAudioSession;
@end
static unsigned InitialStartFailures=0;
@interface GateEngine : SDBEngine
@property(nonatomic) GateAudioMixer *transport;
@property(nonatomic) BOOL denyActivation;
@end
@implementation GateEngine
- (SDBAudioMixer *)newAudioMixer {
    self.transport=[GateAudioMixer new];self.transport.startFailures=InitialStartFailures;
    return (SDBAudioMixer *)self.transport;
}
- (BOOL)activateAudioSession {
    [self setValue:(_denyActivation?@"Simulated higher-priority system audio":nil) forKey:@"audioSessionError"];
    return !_denyActivation;
}
@end

namespace {
unsigned checks=0;
bool require(bool value,const char *message) {++checks;if(!value)fprintf(stderr,"FAIL %s\n",message);return value;}
Runtime *runtime(SDBEngine *engine) {
    Ivar ivar=class_getInstanceVariable(SDBEngine.class,"_runtime");
    if (!ivar) return nullptr;
    const ptrdiff_t offset=ivar_getOffset(ivar);
    if (offset<0 || size_t(offset)+sizeof(std::unique_ptr<Runtime>)>class_getInstanceSize(SDBEngine.class)) return nullptr;
    auto *object=static_cast<uint8_t *>((__bridge void *)engine);
    return reinterpret_cast<std::unique_ptr<Runtime> *>(object+offset)->get();
}
bool advance(SDBEngine *engine,unsigned count=120) {
    for (unsigned index=0;index<count;++index) [engine advanceSimulation:1.0/60];
    [engine renderFrame];return require(!engine.failure,"original guest remains healthy");
}
bool activate(SDBEngine *engine,NSString *label) {
    for (SDBMenuAction *action in engine.menuActions) if ([action.label isEqual:label])
        return require([engine activateMenuAction:action.identifier],"original menu action accepted")&&advance(engine);
    return require(false,"original menu action is available");
}
unsigned effectsPlayed(GateAudioMixer *mixer) {
    unsigned count=0;for(unsigned index=0;index<8;++index)count+=mixer.voices[index].playCount;return count;
}
bool effect(SDBEngine *engine,Runtime *r) {
    r->cpu.call(0xe995,{r->sound,0});return require(!engine.failure&&r->cpu.fault.empty(),"original menu sound request stays valid");
}
}

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if(argc!=3)return 64;
        setenv("SDB_SAVE_DIRECTORY",argv[2],1);setenv("SDB_MUTE_AUDIO","1",1);setenv("SDB_CPU_RENDERER","1",1);
        GateEngine *engine=[[GateEngine alloc]initWithResourcePath:[NSString stringWithUTF8String:argv[1]] offersHaptics:YES];
        if(!advance(engine)||!activate(engine,@"Game Start")||!advance(engine,240))return 1;
        Runtime *r=runtime(engine);GateAudioMixer *mixer=engine.transport;
        if(!require(r&&engine.gameMenuType==0&&mixer.loadCount==12,"actual original game starts with twelve native buffers"))return 1;
        r->cpu.call(0xea15,{r->sound,1,1});
        GateAudioVoice *music=mixer.voices[8];
        if(!require(r->cpu.fault.empty()&&music.playing,"original music bridge starts the persistent music voice"))return 1;
        [engine pauseGame];
        const auto memory=r->cpu.memory;const auto registers=r->cpu.r;const auto instructions=r->cpu.instructionCount;
        [engine setAudioSuspended:YES];
        if(!require(engine.audioSuspended&&!music.playing&&!mixer.prepared&&
                    r->cpu.memory==memory&&r->cpu.r==registers&&r->cpu.instructionCount==instructions,
                    "audio-only suspension pauses native music without executing or changing the guest"))return 1;
        const unsigned beforeEffects=effectsPlayed(mixer);
        if(!advance(engine)||!require(engine.gameMenuType==3&&engine.menuActions.count==2,
                    "original Pause menu finishes its animation while native audio is suspended")||!effect(engine,r))return 1;
        if(!require(effectsPlayed(mixer)==beforeEffects&&!music.playing&&!mixer.prepared,"gated original menu sounds never play"))return 1;
        [engine setSuspended:YES];const unsigned prepareCount=mixer.prepareCount;[engine setSuspended:NO];
        if(!require(engine.audioSuspended&&mixer.prepareCount==prepareCount&&!music.playing,
                    "guest scheduling can resume without bypassing the independent audio gate")||!advance(engine))return 1;
        engine.denyActivation=YES;
        if(!require(![engine tryResumeAudio]&&engine.audioSuspended&&engine.lastAudioError.length&&!engine.failure,
                    "higher-priority OS audio leaves a retryable gate rather than a guest fault"))return 1;
        engine.denyActivation=NO;mixer.startFailures=1;
        if(!require(![engine tryResumeAudio]&&engine.audioSuspended&&engine.lastAudioError.length&&!engine.failure,
                    "native startup failure is nonfatal and keeps audio stopped"))return 1;
        const unsigned rebuildCount=mixer.rebuildCount;
        if(!require([engine tryResumeAudio]&&!engine.audioSuspended&&!engine.lastAudioError&&
                    mixer.rebuildCount==rebuildCount+1&&music.playing&&mixer.loadCount==12,
                    "explicit retry rebuilds sticky native failure while retaining buffers and music identity")||
           !require(effectsPlayed(mixer)==beforeEffects,"recovery does not replay interrupted or gated effects")||!effect(engine,r)||
           !require(effectsPlayed(mixer)==beforeEffects+1,"a fresh original sound plays after recovery"))return 1;
        [engine setSuspended:YES];
        if(!require([engine tryResumeAudio]&&!music.playing&&!mixer.prepared,
                    "successful activation cannot start voices while the full guest is suspended"))return 1;
        [engine setSuspended:NO];
        if(!require(music.playing&&!engine.audioSuspended&&!engine.failure,"ordinary full resume restores prior music intent"))return 1;
        const unsigned resetPrepares=mixer.prepareCount;
        if(!require([engine recoverAudioAfterMediaServicesReset]&&engine.audioSuspended&&!music.playing&&
                    mixer.prepareCount==resetPrepares&&mixer.loadCount==12,
                    "media reset rebuilds native graph without activating or reloading original buffers")||
           !require([engine tryResumeAudio]&&music.playing,"explicit activation restores reset music"))return 1;
        [engine setAudioSuspended:YES];mixer.failure=@"Simulated stale startup failure";mixer.rebuildFailures=1;
        if(!require(![engine tryResumeAudio]&&engine.audioSuspended&&!engine.failure,
                    "a failed native rebuild remains retryable")||
           !require([engine tryResumeAudio]&&!engine.audioSuspended&&!engine.lastAudioError,
                    "a later rebuild/activation succeeds without replacing the guest"))return 1;
        for(unsigned index=0;index<8;++index)mixer.voices[index].failPlay=YES;
        if(!effect(engine,r)||!require(engine.audioSuspended&&engine.lastAudioError.length&&!engine.failure,
                    "a native voice start failure gates audio without poisoning gameplay")||
           !require([engine tryResumeAudio]&&!engine.audioSuspended,"fresh activation can recover a transient voice failure"))return 1;
        music.failPlay=YES;r->cpu.call(0xea15,{r->sound,1,1});
        if(!require(engine.audioSuspended&&!music.playing&&!engine.failure,
                    "a failed new music request retains explicit recovery intent")||
           !require([engine tryResumeAudio]&&music.playing,"retry restarts music whose initial native play failed"))return 1;
        NSString *startup=[[NSString stringWithUTF8String:argv[2]]stringByAppendingPathComponent:@"startup"];
        setenv("SDB_SAVE_DIRECTORY",startup.UTF8String,1);InitialStartFailures=1;
        GateEngine *busy=[[GateEngine alloc]initWithResourcePath:[NSString stringWithUTF8String:argv[1]] offersHaptics:YES];
        InitialStartFailures=0;
        if(!advance(busy)||!require(busy.gameMenuType==1&&busy.audioSuspended&&!busy.failure,
                    "busy startup audio still constructs and renders the original title")||
           !require([busy tryResumeAudio]&&!busy.audioSuspended&&!busy.lastAudioError,
                    "initial native audio failure recovers on a later explicit attempt"))return 1;
        printf("PASS %u actual-engine audio gate/retry checks; native transport injected, no output device or live preferences\n",checks);
    }
}
