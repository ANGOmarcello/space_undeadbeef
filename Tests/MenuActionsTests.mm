// Created by Angelo Cammalleri on 27.10.2026.
#import "SDBEngine.h"
#import "SDBSaveStore.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace {
unsigned checks = 0;
bool require(bool value, const char *message) {++checks; if (!value) fprintf(stderr, "FAIL %s\n", message); return value;}
bool advance(SDBEngine *engine, unsigned count = 120) {
    for (unsigned frame = 0; frame < count; ++frame) [engine advanceSimulation:1.0 / 60];
    if (engine.failure) fprintf(stderr, "Guest fault: %s\n", engine.failure.UTF8String);
    return require(!engine.failure, "original simulation remains healthy");
}
SDBMenuAction *action(SDBEngine *engine, NSString *label) {
    for (SDBMenuAction *candidate in engine.menuActions) if ([candidate.label isEqual:label]) return candidate;
    return nil;
}
bool activate(SDBEngine *engine, NSString *label) {
    SDBMenuAction *item = action(engine, label);
    if (!item) {fprintf(stderr, "Missing action: %s; menu=%ld actions=%s\n", label.UTF8String,
        long(engine.gameMenuType), engine.menuActions.description.UTF8String); return false;}
    return require([engine activateMenuAction:item.identifier], "live original action accepted") && advance(engine);
}
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 64;
        setenv("SDB_SAVE_DIRECTORY", argv[2], 1); setenv("SDB_MUTE_AUDIO", "1", 1); setenv("SDB_CPU_RENDERER", "1", 1);
        SDBEngine *engine = [[SDBEngine alloc] initWithResourcePath:[NSString stringWithUTF8String:argv[1]] offersHaptics:YES];
        if (!advance(engine) || !require(engine.gameMenuType == 1 && engine.menuActions.count == 4, "title exposes four original actions")) return 1;
        SDBMenuAction *start = action(engine, @"Game Start"), *oldOptions = action(engine, @"Options");
        if (!require(start && CGRectContainsPoint(start.logicalFrame, CGPointMake(160, 40)), "action frame matches original Game Start hit area") ||
            !activate(engine, @"Options") ||
            !require(engine.gameMenuType == 5 && engine.menuActions.count == 10, "extended original Options exposes ten controls") ||
            !require(![engine activateMenuAction:start.identifier] && ![engine activateMenuAction:oldOptions.identifier], "stale title actions rejected") ||
            !require(action(engine, @"Sound On").selected && action(engine, @"Respect Silent Mode On").selected && action(engine, @"Haptics On").selected,
                     "selected values match native defaults")) return 1;
        if (!activate(engine, @"Sound Off") || !require(!engine.soundEnabled && action(engine, @"Sound Off").selected, "original sound callback updates selection") ||
            !activate(engine, @"Respect Silent Mode Off") || !require(!engine.respectsSilentMode, "original extended silent callback") ||
            !activate(engine, @"Haptics Off") || !require(!engine.hapticsEnabled, "original extended haptics callback") ||
            !activate(engine, @"Save and Exit") || !require(engine.gameMenuType == 1, "original SAVE-EXIT returns to title") ||
            !require([engine saveProgress] && !engine.lastSaveError, "explicit original save succeeds")) return 1;
        NSString *saveFile = [[NSString stringWithUTF8String:argv[2]] stringByAppendingPathComponent:@"savedata.dat"];
        if (!require([SDBSaveStore isValidOriginalData:[NSData dataWithContentsOfFile:saveFile]], "engine retains original 256-byte save format") ||
            !activate(engine, @"Credits") || !require(engine.gameMenuType == 6 && engine.menuActions.count == 1, "credits exposes original exit")) return 1;
        SDBMenuAction *creditsBack = action(engine, @"Back");
        const CGPoint creditsCenter = CGPointMake(CGRectGetMidX(creditsBack.logicalFrame), CGRectGetMidY(creditsBack.logicalFrame));
        [engine touchPhase:0 x:creditsCenter.x y:creditsCenter.y];
        if (!advance(engine, 12)) return 1;
        [engine touchPhase:2 x:creditsCenter.x y:creditsCenter.y];
        if (!advance(engine) || !require(engine.gameMenuType == 1, "raw center tap follows Credits Back through GameManager input") ||
            !activate(engine, @"Credits") ||
            !activate(engine, @"Back") || !require(engine.gameMenuType == 1, "credits exit follows original callback")) return 1;
        [engine configureViewport:CGSizeMake(874,402) displayScale:1 safeArea:CGRectMake(0,0,874,402)];
        if (!activate(engine, @"Credits")) return 1;
        [engine renderFrame];
        creditsBack = action(engine, @"Back");
        const CGPoint wideCenter = CGPointMake(CGRectGetMidX(creditsBack.logicalFrame), CGRectGetMidY(creditsBack.logicalFrame));
        const CGPoint canvasCenter=CGPointMake(engine.logicalSize.width/2,engine.logicalSize.height/2);
        if (!require(!CGRectContainsPoint(creditsBack.logicalFrame,canvasCenter),
                     "Credits Back exposes its original lower row rather than the whole canvas")) return 1;
        [engine touchPhase:0 x:canvasCenter.x y:canvasCenter.y];
        if (!advance(engine,12)) return 1;
        [engine touchPhase:2 x:canvasCenter.x y:canvasCenter.y];
        if (!advance(engine) || !require(engine.gameMenuType==6,"canvas-center touch remains outside the original Credits Back row")) return 1;
        [engine touchPhase:0 x:wideCenter.x y:wideCenter.y];
        if (!advance(engine,1)) return 1;
        [engine touchPhase:1 x:wideCenter.x+.1 y:wideCenter.y];
        if (!advance(engine,11)) return 1;
        [engine touchPhase:2 x:wideCenter.x+.1 y:wideCenter.y];
        if (!advance(engine) || !require(engine.gameMenuType == 1, "wide iPhone Back-row press follows original input despite small finger movement")) return 1;
        [engine configureViewport:CGSizeMake(480,320) displayScale:1 safeArea:CGRectMake(0,0,480,320)];
        NSDictionary *snapshot = engine.progressPortableSnapshot;
        if (!require(snapshot && [engine importValidatedProgress:snapshot], "title accepts validated unchanged portable record") ||
            !require(![engine importValidatedProgress:@{@"schema":@999}], "future progress schema rejected") ||
            !activate(engine, @"Game Start") || !require(engine.canPause && engine.menuActions.count == 0, "gameplay exposes no menu actions") ||
            !require(![engine importValidatedProgress:snapshot], "portable import rejected during gameplay")) return 1;
        if (!advance(engine, 240)) return 1;
        [engine touchPhase:0 x:60 y:160];
        if (!advance(engine, 3) || !require(engine.shipAiming, "ordinary held input begins original aiming")) return 1;
        (void)[engine consumeHapticEvents];
        [engine cancelHeldInput];
        if (!require(!engine.shipAiming && ([engine consumeHapticEvents] & 1) == 0,
                     "host cancellation ends original aiming without a release volley")) return 1;
        [engine touchPhase:0 x:60 y:160];
        if (!advance(engine, 3) || !require(engine.shipAiming, "fresh charge works after cancellation")) return 1;
        [engine cancelHeldInput];
        NSDictionary *earned = engine.progressPortableSnapshot;
        if (!require(earned && [earned[@"checkpoint"] unsignedIntegerValue] > 0, "natural original gameplay produces portable checkpoint")) return 1;
        NSDictionary *mergedPortable = [SDBEngine mergedPortableSnapshot:snapshot remote:earned];
        if (!require([mergedPortable[@"checkpoint"] isEqual:earned[@"checkpoint"]], "pure class merge retains farther earned checkpoint") ||
            !require([SDBEngine mergedPortableSnapshot:earned remote:@{@"schema":@99}] == nil, "pure class merge rejects future schema")) return 1;
        NSString *receiverPath = [[NSString stringWithUTF8String:argv[2]] stringByAppendingPathComponent:@"receiver"];
        setenv("SDB_SAVE_DIRECTORY", receiverPath.UTF8String, 1);
        SDBEngine *receiver = [[SDBEngine alloc] initWithResourcePath:[NSString stringWithUTF8String:argv[1]] offersHaptics:YES];
        if (!advance(receiver) || !require([receiver importValidatedProgress:earned], "title merges earned progress through original unpack") ||
            !require([receiver.progressPortableSnapshot[@"checkpoint"] isEqual:earned[@"checkpoint"]] &&
                     [receiver.progressPortableSnapshot[@"highScore"] isEqual:earned[@"highScore"]], "checkpoint/high score survive original load") ||
            !require(receiver.soundEnabled && receiver.respectsSilentMode && receiver.hapticsEnabled,
                     "portable import retains receiving host preferences")) return 1;
        receiver = nil;
        setenv("SDB_SAVE_DIRECTORY", argv[2], 1);
        [engine pauseGame];
        if (!advance(engine) || !require(engine.gameMenuType == 3 && engine.menuActions.count == 2, "original pause exposes Resume and Quit") ||
            !require(![engine importValidatedProgress:snapshot], "portable import rejected while paused") ||
            !activate(engine, @"Resume") || !require(engine.gameMenuType == 0, "original resume callback restores gameplay")) return 1;
        [engine pauseGame];
        if (!advance(engine) || !activate(engine, @"Quit") || !require(engine.gameMenuType == 1, "pause Quit ends game through original callback")) return 1;
        [engine setSuspended:YES];
        if (!require(engine.menuActions.count == 0 && ![engine activateMenuAction:start.identifier], "inactive menu actions unavailable") ||
            !require(!engine.failure && !engine.lastSaveError, "lifecycle save and suspend remain healthy")) return 1;
        engine = nil;
        engine = [[SDBEngine alloc] initWithResourcePath:[NSString stringWithUTF8String:argv[1]] offersHaptics:YES];
        if (!advance(engine) || !require(!engine.soundEnabled && !engine.respectsSilentMode && !engine.hapticsEnabled,
                                        "host preferences survive save/relaunch independently")) return 1;
        printf("Passed %u original menu/save integration checks.\n", checks);
    }
}
