//
//  WatchControlsSmoke.mm
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//
// Public-engine Watch controls, using original gameplay and its software renderer.
// No direct guest-memory, position, health, scenario or instruction writes.

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import "SDBEngine.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>

namespace {
unsigned checks = 0;
bool require(bool condition, const char *label) {
    ++checks;
    if (!condition) std::fprintf(stderr, "FAIL %s\n", label);
    return condition;
}
#define REQUIRE(condition, label) do { if (!require((condition), (label))) return 1; } while (0)
bool healthy(SDBEngine *engine) {
    if (engine && !engine.failure) return true;
    std::fprintf(stderr, "FAIL original engine: %s\n%s\n", engine.failure.UTF8String ?: "missing engine", engine.diagnostics.UTF8String ?: "");
    return false;
}
bool advance(SDBEngine *engine, unsigned frames) {
    for (unsigned frame = 0; frame < frames; ++frame) {
        [engine advanceSimulation:1.0 / 60.0];
        if (!healthy(engine)) return false;
    }
    return true;
}
bool advanceWithinBounds(SDBEngine *engine, unsigned frames) {
    for (unsigned frame = 0; frame < frames; ++frame) {
        if (!advance(engine, 1) || engine.shipNormalizedY < -.000001 || engine.shipNormalizedY > 1.000001)
            return false;
    }
    return true;
}
CGPoint originalPoint(SDBEngine *engine, double x, double y) {
    return CGPointMake(engine.logicalSize.width / 2 + x - 240, engine.logicalSize.height / 2 + y - 160);
}
bool tap(SDBEngine *engine, double x, double y) {
    CGPoint point = originalPoint(engine, x, y);
    [engine touchPhase:0 x:point.x y:point.y];
    if (!advance(engine, 1)) return false;
    [engine touchPhase:2 x:point.x y:point.y];
    return advance(engine, 120);
}
uint64_t audioCount(SDBEngine *engine) {
    const char *value = std::strstr(engine.diagnostics.UTF8String, "audio=");
    return value ? std::strtoull(value + 6, nullptr, 10) : UINT64_MAX;
}
SDBEngine *fresh(NSString *resources, NSString *scratch, NSString *name, BOOL start) {
    NSString *save = [scratch stringByAppendingPathComponent:name];
    setenv("SDB_SAVE_DIRECTORY", save.fileSystemRepresentation, 1);
    SDBEngine *engine = [[SDBEngine alloc] initWithResourcePath:resources];
    if (!healthy(engine)) return nil;
    engine.watchLayout = YES;
    [engine configureViewport:CGSizeMake(208, 248) displayScale:2 safeArea:CGRectMake(0, 0, 208, 248)];
    if (!healthy(engine) || !advance(engine, 120)) return nil;
    if (start && (!tap(engine, 160, 40) || !engine.canPause || !advance(engine, 180))) return nil;
    return engine;
}
bool capture(SDBEngine *engine, NSString *directory, NSString *name) {
    [engine renderFrame];
    if (!healthy(engine) || !engine.frame) return false;
    NSString *path = [directory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]];
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef output = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, nullptr);
    if (!output) return false;
    CGImageDestinationAddImage(output, engine.frame, nullptr);
    bool ok = CGImageDestinationFinalize(output);
    CFRelease(output);
    std::printf("CAPTURE %s shipY=%.6f aiming=%d\n", path.fileSystemRepresentation, engine.shipNormalizedY, engine.shipAiming);
    return ok;
}

int movement(NSString *resources, NSString *scratch, NSString *captures) {
    SDBEngine *engine = fresh(resources, scratch, @"movement", NO);
    REQUIRE(engine && engine.watchLayout && !engine.usesMetalRenderer, "explicit Watch policy uses software renderer");
    const double titleY = engine.shipNormalizedY;
    [engine steerShipToNormalizedY:.1];
    REQUIRE(advance(engine, 30) && engine.gameMenuType == 1 && !engine.shipAiming && engine.shipNormalizedY == titleY,
            "Crown input is ignored on original title without beginning aim");
    REQUIRE(tap(engine, 160, 40) && engine.canPause, "original Game Start reaches playable ship");
    REQUIRE(advance(engine, 180), "allow original automatic entrance before steering input");
    REQUIRE(std::abs(engine.shipNormalizedY - .5) < .001 && !engine.shipAiming, "actual ship starts centered without a held marker");
    REQUIRE(capture(engine, captures, @"00-center"), "capture original center ship and Watch HUD");
    [engine steerShipToNormalizedY:.2];
    REQUIRE(advance(engine, 90), "advance original spring toward upper input");
    const double up = engine.shipNormalizedY;
    std::printf("MOVEMENT upper=%.6f\n", up);
    REQUIRE(std::abs(up - .2) < .025 && !engine.shipAiming, "Crown moves actual ship upward without aim/charge");
    REQUIRE(capture(engine, captures, @"01-up"), "capture actual upper ship");
    [engine steerShipToNormalizedY:.8];
    REQUIRE(advance(engine, 90), "advance original spring toward lower input");
    const double down = engine.shipNormalizedY;
    std::printf("MOVEMENT lower=%.6f playable=%d\n", down, engine.canSteerShip);
    REQUIRE(std::abs(down - .8) < .08 && down > up + .5 && engine.canSteerShip && !engine.shipAiming,
            "Crown reverses actual ship movement without an aiming touch");
    REQUIRE(capture(engine, captures, @"02-down"), "capture actual lower ship");
    // Independent original starts prevent later incoming enemies/death from
    // being mistaken for a steering clamp. Health and scenario stay untouched.
    engine = fresh(resources, scratch, @"lower-clamp", YES);
    REQUIRE(engine && engine.canSteerShip, "fresh playable original ship for lower bound");
    [engine steerShipToNormalizedY:100];
    REQUIRE(advanceWithinBounds(engine, 120) && engine.shipNormalizedY > .98 && !engine.shipAiming,
            "finite oversized Crown request obeys original lower radius clamp");
    engine = fresh(resources, scratch, @"upper-clamp", YES);
    REQUIRE(engine && engine.canSteerShip, "fresh playable original ship for upper bound");
    [engine steerShipToNormalizedY:-100];
    REQUIRE(advanceWithinBounds(engine, 120) && engine.shipNormalizedY < .02 && !engine.shipAiming,
            "finite negative Crown request obeys original upper radius clamp");
    engine = fresh(resources, scratch, @"cancel", YES);
    REQUIRE(engine && engine.canSteerShip, "fresh stationary original ship for cancelled-input check");
    [engine steerShipToNormalizedY:.9];
    [engine cancelShipSteering];
    const double stopped = engine.shipNormalizedY;
    [engine steerShipToNormalizedY:NAN];[engine steerShipToNormalizedY:INFINITY];
    REQUIRE(advance(engine, 60) && std::abs(engine.shipNormalizedY - stopped) < .001 && !engine.shipAiming,
            "cancelled Crown target and invalid input never enter original physics or hold a marker");
    return 0;
}

int coexistence(NSString *resources, NSString *scratch) {
    SDBEngine *engine = fresh(resources, scratch, @"touch", YES);
    REQUIRE(engine, "fresh original gameplay for touch and Crown ownership");
    [engine steerShipToNormalizedY:.1];
    // An actual new aiming touch takes ownership before any Crown step.
    [engine touchPhase:0 x:60 y:engine.logicalSize.height * .75];
    [engine steerShipToNormalizedY:.05];
    REQUIRE(advance(engine, 90) && engine.shipAiming && engine.shipNormalizedY > .65,
            "real touch drag wins over Crown requests and retains normal aiming");
    [engine touchPhase:2 x:60 y:engine.logicalSize.height * .75];
    REQUIRE(!engine.shipAiming, "original touch release clears its marker");
    [engine touchPhase:0 x:60 y:engine.logicalSize.height * .65];
    REQUIRE(advance(engine, 8) && engine.shipAiming, "original aim begins before cancellation handoff");
    [engine touchPhase:3 x:60 y:engine.logicalSize.height * .65];
    REQUIRE(engine.shipAiming, "record original Game touchCancelled no-op marker behavior");
    const uint64_t sounds = audioCount(engine);
    [engine steerShipToNormalizedY:.3];
    REQUIRE(!engine.shipAiming && audioCount(engine) == sounds,
            "Crown handoff ends stale marker through original ended without releasing a volley");
    REQUIRE(advance(engine, 90) && std::abs(engine.shipNormalizedY - .3) < .08 && !engine.shipAiming,
            "Crown steers actual ship after cancelled touch without stale charge");
    [engine cancelShipSteering];
    const double beforeMove = engine.shipNormalizedY;
    [engine touchPhase:1 x:60 y:engine.logicalSize.height * .9];
    REQUIRE(advance(engine, 30) && std::abs(engine.shipNormalizedY - beforeMove) < .08 && !engine.shipAiming,
            "Crown never creates a host touch that a stray move could keep held");
    return 0;
}

int lifecycle(NSString *resources, NSString *scratch, NSString *captures) {
    SDBEngine *engine = fresh(resources, scratch, @"lifecycle", YES);
    REQUIRE(engine, "fresh original gameplay for pause and resizing");
    [engine steerShipToNormalizedY:.25];
    REQUIRE(advance(engine, 90) && std::abs(engine.shipNormalizedY - .25) < .025, "establish actual ship position before pause");
    [engine pauseGame];
    const double paused = engine.shipNormalizedY;
    [engine steerShipToNormalizedY:.95];
    REQUIRE(advance(engine, 120) && engine.gameMenuType == 3 && engine.shipNormalizedY == paused && !engine.shipAiming,
            "Pause ignores Crown and freezes actual ship without aim");
    REQUIRE(capture(engine, captures, @"03-pause"), "capture original Pause menu on Watch layout");
    REQUIRE(tap(engine, 240, 130) && engine.canPause, "original Continue resumes gameplay");
    REQUIRE(advance(engine, 30) && std::abs(engine.shipNormalizedY - paused) < .08 && !engine.shipAiming,
            "Pause cleared old Crown target instead of replaying it after Continue");
    [engine steerShipToNormalizedY:.75];
    [engine configureViewport:CGSizeMake(200, 260) displayScale:2 safeArea:CGRectMake(0, 0, 200, 260)];
    const double resized = engine.shipNormalizedY;
    REQUIRE(advance(engine, 60) && std::abs(engine.shipNormalizedY - resized) < .005 && !engine.shipAiming,
            "resize cancels Crown target and preserves original ship state");
    [engine steerShipToNormalizedY:.7];
    [engine setSuspended:YES];
    const double suspended = engine.shipNormalizedY;
    [engine steerShipToNormalizedY:.9];
    REQUIRE(advance(engine, 30) && engine.shipNormalizedY == suspended && !engine.shipAiming,
            "inactive engine ignores Crown input and leaves ship frozen");
    [engine setSuspended:NO];
    REQUIRE(advance(engine, 30) && std::abs(engine.shipNormalizedY - suspended) < .005 && !engine.shipAiming,
            "resume preserves ship anchor without replaying stale Crown input");
    return 0;
}
}

int main(int argc, char **argv) {
    if (argc != 4) { std::fprintf(stderr, "Usage: WatchControlsSmoke resources task-scratch capture-directory\n"); return 64; }
    @autoreleasepool {
        NSString *scratch = [NSString stringWithUTF8String:argv[2]], *captures = [NSString stringWithUTF8String:argv[3]];
        auto temporary = [](NSString *path) {
            std::error_code error;
            const auto resolved = std::filesystem::weakly_canonical(path.fileSystemRepresentation, error);
            if (error) return false;
            const auto root = std::filesystem::weakly_canonical("/private/tmp", error);
            return !error && resolved.string().find(root.string() + "/") == 0;
        };
        if (!temporary(scratch) || !temporary(captures)) {
            std::fprintf(stderr, "Scratch/captures must resolve inside task-owned /private/tmp storage.\n");return 64;
        }
        if (![NSFileManager.defaultManager createDirectoryAtPath:captures withIntermediateDirectories:YES attributes:nil error:nil]) return 1;
        setenv("SDB_CPU_RENDERER", "1", 1);setenv("SDB_MUTE_AUDIO", "1", 1);
        NSString *resources = [NSString stringWithUTF8String:argv[1]];
        int result = 0;
        @autoreleasepool { result = movement(resources, scratch, captures); }
        if (!result) @autoreleasepool { result = coexistence(resources, scratch); }
        if (!result) @autoreleasepool { result = lifecycle(resources, scratch, captures); }
        if (!result) std::printf("PASS %u Watch engine control checks: actual original ship spring/clamps, no Crown aim, touch ownership, stale-marker handoff without volley, pause/resize/inactivity cancellation; software rendering only.\n", checks);
        return result;
    }
}
