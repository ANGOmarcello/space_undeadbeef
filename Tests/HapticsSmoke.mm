//
//  HapticsSmoke.mm
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//
// Exercises original menus/gameplay through the public engine API. It observes
// haptic event bits; it does not invoke a physical haptic device or patch health,
// scenario, targeting, audio requests, or the original instruction stream.

#import <Foundation/Foundation.h>
#import "SDBEngine.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {
constexpr double Step = 1.0 / 60.0;
constexpr NSUInteger LaserReleased = 1, TargetAcquired = 2, PlayerDamaged = 4;
constexpr NSUInteger KnownEvents = LaserReleased | TargetAcquired | PlayerDamaged;
unsigned checks = 0;
bool require(bool condition, const char *label) {
    ++checks;
    if (!condition) std::fprintf(stderr, "FAIL %s\n", label);
    return condition;
}
#define REQUIRE(condition, label) do { if (!require((condition), (label))) return 1; } while (0)

bool healthy(SDBEngine *engine, const char *label) {
    if (engine && !engine.failure) return true;
    std::fprintf(stderr, "FAIL %s: %s\n%s\n", label, engine.failure.UTF8String ?: "no engine",
                 engine.diagnostics.UTF8String ?: "");
    return false;
}
bool advance(SDBEngine *engine, unsigned frames) {
    for (unsigned frame = 0; frame < frames; ++frame) {
        @autoreleasepool { [engine advanceSimulation:Step]; }
        if (!healthy(engine, "original simulation")) return false;
    }
    return true;
}
bool tap(SDBEngine *engine, double x, double y) {
    [engine touchPhase:0 x:x y:y];
    if (!advance(engine, 1)) return false;
    [engine touchPhase:2 x:x y:y];
    return advance(engine, 120);
}
bool options(SDBEngine *engine) {
    return advance(engine, 120) && tap(engine, 160, 120) && engine.gameMenuType == 5;
}
bool stored(NSString *directory, NSString *key, BOOL expected) {
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:
        [directory stringByAppendingPathComponent:@"audio-preferences.plist"]];
    NSNumber *value = preferences[key];
    return value && value.boolValue == expected;
}
SDBEngine *fresh(NSString *resources) {
    return [[SDBEngine alloc] initWithResourcePath:resources offersHaptics:YES];
}
uint64_t audioCount(SDBEngine *engine) {
    const char *value = std::strstr(engine.diagnostics.UTF8String, "audio=");
    return value ? std::strtoull(value + 6, nullptr, 10) : UINT64_MAX;
}

int run(NSString *resources, NSString *directory) {
    SDBEngine *engine = fresh(resources);
    REQUIRE(healthy(engine, "initialize haptics-capable host"), "initialize original engine");
    REQUIRE(!engine.hapticsEnabled && [engine consumeHapticEvents] == 0, "new installation defaults Haptics OFF");
    REQUIRE(options(engine), "open actual original Options menu");
    REQUIRE(tap(engine, 180, 250) && engine.hapticsEnabled, "actual Options Haptics ON callback takes effect");
    REQUIRE(stored(directory, @"feedback.hapticsEnabled", YES), "ON persists before SAVE-EXIT");
    engine = fresh(resources);
    REQUIRE(healthy(engine, "recreate after ON") && engine.hapticsEnabled, "ON survives engine recreation");
    REQUIRE(options(engine) && tap(engine, 300, 250) && !engine.hapticsEnabled,
            "actual Options Haptics OFF callback takes effect");
    REQUIRE(stored(directory, @"feedback.hapticsEnabled", NO), "OFF persists before SAVE-EXIT");
    engine = fresh(resources);
    REQUIRE(healthy(engine, "recreate after OFF") && !engine.hapticsEnabled, "OFF survives engine recreation");
    REQUIRE(options(engine) && tap(engine, 180, 250) && engine.hapticsEnabled, "actual menu can restore Haptics ON");
    REQUIRE(tap(engine, 300, 130) && !engine.soundEnabled && engine.hapticsEnabled,
            "actual Sound OFF preserves independent Haptics ON");
    REQUIRE(stored(directory, @"audio.soundEnabled", NO) && stored(directory, @"feedback.hapticsEnabled", YES),
            "Sound OFF and Haptics ON persist independently");
    REQUIRE(tap(engine, 240, 280) && engine.gameMenuType == 1, "actual SAVE-EXIT returns to title");
    engine = fresh(resources);
    REQUIRE(healthy(engine, "recreate independent preferences") && !engine.soundEnabled && engine.hapticsEnabled,
            "Sound OFF and Haptics ON survive recreated engine");
    REQUIRE(advance(engine, 120) && [engine consumeHapticEvents] == 0, "title emits no gameplay feedback");
    REQUIRE(tap(engine, 160, 40) && engine.canPause, "actual Game Start enters ordinary gameplay");
    REQUIRE(audioCount(engine) == 0, "original Sound-OFF guard suppresses audio playback requests");

    unsigned releaseEvents = 0, lockEvents = 0, damageEvents = 0, releases = 0, gameplaySteps = 0;
    NSUInteger allEvents = 0;
    auto collect = [&]() {
        NSUInteger events = [engine consumeHapticEvents];
        if ((events & ~KnownEvents) || [engine consumeHapticEvents] != 0) return false;
        allEvents |= events;
        releaseEvents += bool(events & LaserReleased);
        lockEvents += bool(events & TargetAcquired);
        damageEvents += bool(events & PlayerDamaged);
        return true;
    };
    // This is the same ordinary hold/release/scan workload used by the runtime
    // benchmark. The Continue tap recovers only through the original menu.
    for (unsigned frame = 0; frame < 3000; ++frame) {
        @autoreleasepool {
            if (!engine.canPause) {
                if ((frame % 120) == 0) {
                    double x = engine.gameMenuType == 1 ? 160 : 240;
                    double y = engine.gameMenuType == 1 ? 40 : 130;
                    [engine touchPhase:0 x:x y:y];
                    if (!advance(engine, 1) || !collect()) return 1;
                    [engine touchPhase:2 x:x y:y];
                }
            } else {
                ++gameplaySteps;
                const unsigned phase = frame % 150;
                if (phase == 0) [engine touchPhase:0 x:60 y:160];
                if (phase == 60) { [engine touchPhase:2 x:60 y:160]; ++releases; }
                if (phase == 75) [engine touchPhase:0 x:300 y:80];
                if (phase >= 75 && phase < 135)
                    [engine touchPhase:1 x:300 + 120 * std::sin((phase - 75) * M_PI / 60)
                                     y:80 + (phase - 75) * 2];
                if (phase == 135) { [engine touchPhase:2 x:300 y:200]; ++releases; }
            }
            if (!collect() || !advance(engine, 1) || !collect()) return 1;
            if (engine.soundEnabled || !engine.hapticsEnabled) return 1;
        }
    }
    REQUIRE(gameplaySteps > 600, "workload executes sustained ordinary gameplay");
    REQUIRE((allEvents & (LaserReleased | TargetAcquired)) == (LaserReleased | TargetAcquired),
            "real original laser release and acquired target events survive Sound OFF");
    REQUIRE(releaseEvents <= releases && lockEvents <= gameplaySteps && damageEvents <= gameplaySteps,
            "gameplay event counts remain bounded by original releases and updates");
    REQUIRE(audioCount(engine) == 0, "haptic observation does not bypass the original Sound-OFF audio guard");

    // A separate fresh run leaves the player untouched so incoming enemies can
    // exercise the actual health-decrease observer. Do not manufacture a hit or
    // change health: stop at the ordinary menu transition or sixty game seconds.
    const unsigned activeDamageEvents = damageEvents;
    engine = fresh(resources);
    REQUIRE(healthy(engine, "fresh passive run") && !engine.soundEnabled && engine.hapticsEnabled,
            "fresh passive run retains independent feedback and audio choices");
    REQUIRE(advance(engine, 120) && tap(engine, 160, 40) && engine.canPause,
            "original Game Start enters passive gameplay");
    unsigned passiveSteps = 0;
    if (!collect()) return 1;
    while (passiveSteps < 3600 && engine.gameMenuType == 0) {
        if (!advance(engine, 1) || !collect()) return 1;
        ++passiveSteps;
    }
    const unsigned passiveDamageEvents = damageEvents - activeDamageEvents;
    REQUIRE(passiveSteps > 0 && passiveSteps <= 3600 && passiveDamageEvents <= passiveSteps + 1,
            "passive health observations remain bounded by original gameplay updates");
    REQUIRE(!engine.soundEnabled && engine.hapticsEnabled && audioCount(engine) == 0,
            "passive damage observation preserves Sound OFF");
    std::printf("PASS passive original gameplay=%u updates, damage=%u, finalMenu=%ld; no player input or guest state patches.\n",
                passiveSteps, passiveDamageEvents, (long)engine.gameMenuType);

    engine.hapticsEnabled = NO;
    for (unsigned frame = 0; frame < 240; ++frame) {
        [engine touchPhase:0 x:300 y:80 + frame % 160];
        [engine touchPhase:2 x:300 y:80 + frame % 160];
        REQUIRE(advance(engine, 1) && [engine consumeHapticEvents] == 0, "OFF immediately discards subsequent original gameplay events");
    }
    REQUIRE(!engine.hapticsEnabled && stored(directory, @"feedback.hapticsEnabled", NO), "OFF stays persistent after gameplay");
    engine = fresh(resources);
    REQUIRE(healthy(engine, "final OFF recreation") && !engine.hapticsEnabled && !engine.soundEnabled,
            "gameplay OFF and independent audio preference survive final recreation");
    std::printf("PASS %u haptic integration checks; original gameplay=%u updates, release=%u/%u release inputs, target=%u, damage=%u, audio=0 with Sound OFF.\n",
                checks, gameplaySteps, releaseEvents, releases, lockEvents, damageEvents);
    if (!damageEvents) std::printf("Player damage was not observed in this input run; the guarded damage observer needs separate event coverage.\n");
    std::printf("No physical haptic device was invoked; no universal gameplay event or hardware-feedback claim.\n");
    return 0;
}
}

int main(int argc, char **argv) {
    if (argc != 3 || argv[2][0] != '/') { std::fprintf(stderr, "Usage: HapticsSmoke Resources/Original empty-task-save-directory\n"); return 64; }
    @autoreleasepool {
        NSString *directory = [NSString stringWithUTF8String:argv[2]];
        NSString *canonical = directory.stringByStandardizingPath.stringByResolvingSymlinksInPath;
        if (![canonical hasPrefix:@"/private/tmp/"] && ![canonical hasPrefix:NSTemporaryDirectory().stringByResolvingSymlinksInPath]) {
            std::fprintf(stderr, "Save directory must be inside task-owned system temporary storage.\n"); return 64;
        }
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error] ||
            [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:&error].count != 0) {
            std::fprintf(stderr, "Save directory must be empty.\n"); return 64;
        }
        setenv("SDB_SAVE_DIRECTORY", argv[2], 1);
        setenv("SDB_MUTE_AUDIO", "1", 1);
        return run([NSString stringWithUTF8String:argv[1]], directory);
    }
}
