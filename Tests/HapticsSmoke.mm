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
constexpr NSUInteger WeaponReleased = 1, TargetAcquired = 2, PlayerDamaged = 4;
constexpr NSUInteger MenuSelection = 8, Explosion = 16, PrimaryShot = 32;
constexpr NSUInteger KnownEvents = WeaponReleased | TargetAcquired | PlayerDamaged | MenuSelection | Explosion | PrimaryShot;
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
bool menuFeedback(SDBEngine *engine) {
    NSUInteger events = [engine consumeHapticEvents];
    return (events & MenuSelection) && !(events & ~KnownEvents) && [engine consumeHapticEvents] == 0;
}

int run(NSString *resources, NSString *directory) {
    SDBEngine *engine = fresh(resources);
    REQUIRE(healthy(engine, "initialize haptics-capable host"), "initialize original engine");
    REQUIRE(engine.hapticsEnabled && [engine consumeHapticEvents] == 0, "new installation defaults Haptics ON without title feedback");
    REQUIRE(advance(engine, 120) && tap(engine, 470, 310) && engine.gameMenuType == 1 &&
            [engine consumeHapticEvents] == 0, "empty title-space tap produces no accepted-menu feedback");
    REQUIRE(options(engine), "open actual original Options menu");
    REQUIRE(menuFeedback(engine), "accepted title Options action survives transition to Options menu");
    REQUIRE(tap(engine, 180, 250) && engine.hapticsEnabled, "actual Options Haptics ON callback takes effect");
    REQUIRE(menuFeedback(engine), "Haptics ON produces one coalesced preview in Options");
    REQUIRE(stored(directory, @"feedback.hapticsEnabled", YES), "ON persists before SAVE-EXIT");
    @autoreleasepool {
        SDBEngine *unsupported = [[SDBEngine alloc] initWithResourcePath:resources offersHaptics:NO];
        REQUIRE(healthy(unsupported, "host without haptics") && !unsupported.hapticsEnabled,
                "host without haptics stays disabled even with stored ON preference");
        unsupported.hapticsEnabled = YES;
        REQUIRE(!unsupported.hapticsEnabled && stored(directory, @"feedback.hapticsEnabled", YES) &&
                [unsupported consumeHapticEvents] == 0,
                "unsupported host ignores enable without changing the stored preference");
    }
    engine = fresh(resources);
    REQUIRE(healthy(engine, "recreate after ON") && engine.hapticsEnabled, "ON survives engine recreation");
    REQUIRE(options(engine) && tap(engine, 300, 250) && !engine.hapticsEnabled,
            "actual Options Haptics OFF callback takes effect");
    REQUIRE([engine consumeHapticEvents] == 0, "OFF clears pending accepted-menu feedback and previews");
    REQUIRE(stored(directory, @"feedback.hapticsEnabled", NO), "OFF persists before SAVE-EXIT");
    engine = fresh(resources);
    REQUIRE(healthy(engine, "recreate after OFF") && !engine.hapticsEnabled, "OFF survives engine recreation");
    REQUIRE(options(engine) && tap(engine, 180, 250) && engine.hapticsEnabled, "actual menu can restore Haptics ON");
    REQUIRE(menuFeedback(engine), "OFF-to-ON callback previews feedback while still in Options");
    REQUIRE(tap(engine, 300, 130) && !engine.soundEnabled && engine.hapticsEnabled,
            "actual Sound OFF preserves independent Haptics ON");
    REQUIRE(menuFeedback(engine), "accepted Sound OFF action still supplies independent menu feedback");
    REQUIRE(tap(engine, 470, 310) && engine.gameMenuType == 5 && [engine consumeHapticEvents] == 0,
            "empty Options-space tap produces no menu feedback with Sound OFF");
    REQUIRE(stored(directory, @"audio.soundEnabled", NO) && stored(directory, @"feedback.hapticsEnabled", YES),
            "Sound OFF and Haptics ON persist independently");
    REQUIRE(tap(engine, 240, 280) && engine.gameMenuType == 1, "actual SAVE-EXIT returns to title");
    REQUIRE(menuFeedback(engine), "SAVE-EXIT menu selection survives return to title with Sound OFF");
    engine = fresh(resources);
    REQUIRE(healthy(engine, "recreate independent preferences") && !engine.soundEnabled && engine.hapticsEnabled,
            "Sound OFF and Haptics ON survive recreated engine");
    REQUIRE(advance(engine, 120) && [engine consumeHapticEvents] == 0, "title emits no gameplay feedback");
    REQUIRE(tap(engine, 160, 40) && engine.canPause, "actual Game Start enters ordinary gameplay");
    REQUIRE(menuFeedback(engine), "Game Start selection survives transition into gameplay with Sound OFF");
    REQUIRE(audioCount(engine) == 0, "original Sound-OFF guard suppresses audio playback requests");
    [engine pauseGame];
    REQUIRE(advance(engine, 120) && engine.gameMenuType == 3 && menuFeedback(engine),
            "accepted native Pause original callback emits feedback in Pause menu");
    REQUIRE(tap(engine, 470, 310) && engine.gameMenuType == 3 && [engine consumeHapticEvents] == 0,
            "empty Pause-space tap produces no feedback");
    REQUIRE(tap(engine, 240, 130) && engine.canPause && menuFeedback(engine),
            "accepted Pause Continue feedback survives return to gameplay");

    // Restart through the public title flow so the sustained workload keeps its
    // prior initial conditions after the independent Pause/menu assertions.
    engine = fresh(resources);
    REQUIRE(healthy(engine, "fresh active run") && advance(engine, 120) && tap(engine, 160, 40) &&
            engine.canPause && menuFeedback(engine), "fresh original Game Start for active event workload");

    unsigned releaseEvents = 0, lockEvents = 0, damageEvents = 0, primaryEvents = 0, explosionEvents = 0;
    unsigned releases = 0, gameplaySteps = 0;
    NSUInteger allEvents = 0;
    auto collect = [&]() {
        NSUInteger events = [engine consumeHapticEvents];
        if ((events & ~KnownEvents) || [engine consumeHapticEvents] != 0) return false;
        allEvents |= events;
        releaseEvents += bool(events & WeaponReleased);
        lockEvents += bool(events & TargetAcquired);
        damageEvents += bool(events & PlayerDamaged);
        primaryEvents += bool(events & PrimaryShot);
        explosionEvents += bool(events & Explosion);
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
    std::printf("Observed active events: release=%u primary=%u target=%u explosion=%u damage=%u mask=%lu.\n",
                releaseEvents, primaryEvents, lockEvents, explosionEvents, damageEvents, (unsigned long)allEvents);
    REQUIRE(gameplaySteps > 600, "workload executes sustained ordinary gameplay");
    REQUIRE((allEvents & (WeaponReleased | TargetAcquired | PrimaryShot)) == (WeaponReleased | TargetAcquired | PrimaryShot),
            "real original primary shots, weapon releases and target events survive Sound OFF");
    REQUIRE(releaseEvents <= releases && lockEvents <= gameplaySteps && damageEvents <= gameplaySteps,
            "gameplay event counts remain bounded by original releases and updates");
    REQUIRE(primaryEvents <= gameplaySteps && explosionEvents <= gameplaySteps,
            "actual primary and explosion events coalesce at most once per update");
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
    REQUIRE(explosionEvents > 0, "actual original explosion construction supplies independent feedback with Sound OFF");
    REQUIRE(advance(engine, 120) && engine.gameMenuType == 2 && [engine consumeHapticEvents] == 0,
            "original Game Over entrance settles without unsolicited menu feedback");
    REQUIRE(tap(engine, 470, 310) && engine.gameMenuType == 2 && [engine consumeHapticEvents] == 0,
            "empty Game Over-space tap produces no feedback");
    REQUIRE(engine.gameMenuType == 2 && tap(engine, 240, 130) && engine.canPause && menuFeedback(engine),
            "accepted Game Over Continue feedback survives menu-to-game transition");

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
    std::printf("PASS %u haptic integration checks; original gameplay=%u updates, release=%u/%u release inputs, primary=%u, target=%u, explosion=%u, damage=%u, audio=0 with Sound OFF.\n",
                checks, gameplaySteps, releaseEvents, releases, primaryEvents, lockEvents, explosionEvents, damageEvents);
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
