//
//  ViewportSmoke.mm
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//
// Headless viewport integration proof. All captures, saves and audio preferences
// stay under the caller's task-owned /private/tmp directory. No app is focused.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import "SDBEngine.h"
#include "DisplayGeometry.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using sdb::display::DisplayGeometry;

namespace {
bool check(SDBEngine *engine, const char *stage) {
    if (!engine.failure) return true;
    fprintf(stderr, "FAIL %s: %s\n%s\n", stage, engine.failure.UTF8String, engine.diagnostics.UTF8String);
    return false;
}

uint64_t diagnostic(SDBEngine *engine, const char *key, unsigned base = 10) {
    const char *position = strstr(engine.diagnostics.UTF8String, key);
    return position ? strtoull(position + strlen(key), nullptr, base) : UINT64_MAX;
}

bool menu(SDBEngine *engine, uint32_t wanted, const char *stage) {
    const uint64_t actual = diagnostic(engine, "menuType=");
    if (actual == wanted) return true;
    fprintf(stderr, "FAIL %s: guest menuType=%llu expected=%u\n%s\n", stage,
            (unsigned long long)actual, wanted, engine.diagnostics.UTF8String);
    return false;
}

bool pauseState(SDBEngine *engine, NSInteger wantedMenu, BOOL wantedCanPause, const char *stage) {
    if (!check(engine, stage)) return false;
    if (engine.gameMenuType == wantedMenu && engine.canPause == wantedCanPause) return true;
    fprintf(stderr, "FAIL %s: menuType=%ld canPause=%d expected=%ld/%d\n%s\n", stage,
            (long)engine.gameMenuType, engine.canPause, (long)wantedMenu, wantedCanPause,
            engine.diagnostics.UTF8String);
    return false;
}

bool advance(SDBEngine *engine, unsigned frames, const char *stage) {
    for (unsigned index = 0; index < frames; ++index) {
        @autoreleasepool {
            [engine update:1.0 / 60.0];
            if (!check(engine, stage)) return false;
        }
    }
    printf("PASS %s: %s\n", stage, engine.diagnostics.UTF8String);
    return true;
}

bool capture(SDBEngine *engine, const DisplayGeometry& geometry, NSString *output,
             NSString *name, bool gameplay) {
    // Headless simulation can advance faster than the bounded GPU command
    // queue. Wait once, then render the current state without a simulation tick.
    // Readback occurs only for captures, never for individual gameplay updates.
    if (!engine.frame) { fprintf(stderr, "FAIL capture has no preceding frame\n"); return false; }
    [engine update:0];
    CGImageRef frame = engine.frame;
    if (!frame || !check(engine, "capture current state")) return false;
    const size_t width = CGImageGetWidth(frame), height = CGImageGetHeight(frame);
    if (width != geometry.rasterWidth || height != geometry.rasterHeight ||
        engine.rasterSize.width != width || engine.rasterSize.height != height) {
        fprintf(stderr, "FAIL %s raster is %zux%zu, expected %ux%u\n", name.UTF8String,
                width, height, geometry.rasterWidth, geometry.rasterHeight);
        return false;
    }

    std::vector<uint8_t> rgba(width * height * 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(rgba.data(), width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) { fprintf(stderr, "FAIL capture normalization context\n"); return false; }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), frame);
    CGContextRelease(context);
    std::vector<bool> occupiedColumns(width, false);
    size_t emptyRows = 0, emptyColumns = 0, opaque = 0, outer = 0, occupiedOuter = 0;
    const auto original = geometry.originalArtworkRect;
    const double density = geometry.pixelsPerLogicalUnit;
    for (size_t y = 0; y < height; ++y) {
        bool occupied = false;
        for (size_t x = 0; x < width; ++x) {
            const size_t p = (y * width + x) * 4;
            opaque += rgba[p + 3] == 255;
            const bool content = (rgba[p] | rgba[p + 1] | rgba[p + 2]) != 0;
            occupied |= content; occupiedColumns[x] = occupiedColumns[x] || content;
            const double lx = (x + .5) / density, ly = (y + .5) / density;
            if (lx < original.minX() || lx > original.maxX() ||
                ly < original.minY() || ly > original.maxY()) {
                ++outer; occupiedOuter += content;
            }
        }
        if (y > 1 && y + 2 < height && !occupied) ++emptyRows;
    }
    for (size_t x = 2; x + 2 < width; ++x) emptyColumns += !occupiedColumns[x];
    if (opaque != width * height) {
        fprintf(stderr, "FAIL %s has %zu translucent pixels\n", name.UTF8String, width * height - opaque);
        return false;
    }
    if (gameplay && (emptyRows || emptyColumns)) {
        fprintf(stderr, "FAIL %s gameplay has %zu empty rows and %zu empty columns\n",
                name.UTF8String, emptyRows, emptyColumns);
        return false;
    }
    NSURL *url = [NSURL fileURLWithPath:[output stringByAppendingPathComponent:
        [name stringByAppendingPathExtension:@"png"]]];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, CFSTR("public.png"), 1, nullptr);
    if (!destination) return false;
    CGImageDestinationAddImage(destination, frame, nullptr);
    const bool saved = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    printf("CAPTURE %s raster=%zux%zu opaque=%zu outerNonblack=%.4f emptyRows=%zu emptyColumns=%zu\n",
           url.path.UTF8String, width, height, opaque, outer ? double(occupiedOuter) / outer : 1,
           emptyRows, emptyColumns);
    return saved;
}

struct Case {
    const char *name;
    CGSize size;
    double scale;
    CGRect safe;
};

bool runCase(const Case& variant, NSString *resources, NSString *output) {
    NSString *name = [NSString stringWithUTF8String:variant.name];
    NSString *directory = [output stringByAppendingPathComponent:name];
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                 attributes:nil error:nil]) return false;
    NSString *saves = [directory stringByAppendingPathComponent:@"saves"];
    setenv("SDB_SAVE_DIRECTORY", saves.UTF8String, 1);
    SDBEngine *engine = [[SDBEngine alloc] initWithResourcePath:resources];
    if (!check(engine, "initialize")) return false;
    NSString *wantedVersion = [@"Ver." stringByAppendingString:
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"dev"];
    if (![engine.menuVersion isEqualToString:wantedVersion]) {
        fprintf(stderr, "FAIL native version menu is %s, expected %s\n",
                engine.menuVersion.UTF8String, wantedVersion.UTF8String);
        return false;
    }
    const auto geometry = DisplayGeometry::make({variant.size.width, variant.size.height}, variant.scale,
        {variant.safe.origin.y, variant.safe.origin.x,
         variant.size.height - CGRectGetMaxY(variant.safe), variant.size.width - CGRectGetMaxX(variant.safe)},
        16 * 1024 * 1024);
    if (!geometry.valid) return false;
    [engine configureViewport:variant.size displayScale:variant.scale safeArea:variant.safe];
    if (!check(engine, "configure viewport")) return false;
    if (std::abs(engine.logicalSize.width - geometry.logicalSize.width) > 1e-6 ||
        std::abs(engine.logicalSize.height - geometry.logicalSize.height) > 1e-6) {
        fprintf(stderr, "FAIL %s logical viewport dimensions\n", variant.name); return false;
    }
    printf("CASE %s view=%.3fx%.3f logical=%.3fx%.3f scale=%.1f backend=%s version=%s\n",
           variant.name, variant.size.width, variant.size.height, engine.logicalSize.width,
           engine.logicalSize.height, variant.scale, engine.usesMetalRenderer ? "Metal" : "software",
           engine.menuVersion.UTF8String);
    if (!advance(engine, 120, "title warmup") || !menu(engine, 1, "title warmup") ||
        !capture(engine, geometry, directory, @"01-title", false)) return false;

    // Original START center (160,40): account for the centered artwork region,
    // then the same safe-area/menu offsets applied to the original button data.
    const auto artworkStart = geometry.originalToLogical({160, 40});
    const auto artworkCenter = geometry.originalArtworkRect.center(), safeCenter = geometry.safeUIRect.center();
    const double startX = safeCenter.x + (artworkStart.x - artworkCenter.x) *
        std::min(1.0, geometry.safeUIRect.width / 480);
    const double startY = safeCenter.y + (artworkStart.y - artworkCenter.y) *
        std::min(1.0, geometry.safeUIRect.height / 320);
    const auto viewStart = geometry.logicalToView({startX, startY});
    const CGPoint logicalStart = [engine logicalPointForViewPoint:CGPointMake(viewStart.x, viewStart.y)];
    if (std::abs(logicalStart.x - startX) > 1e-6 || std::abs(logicalStart.y - startY) > 1e-6) {
        fprintf(stderr, "FAIL transformed START touch\n"); return false;
    }
    [engine touchPhase:0 x:logicalStart.x y:logicalStart.y];
    [engine update:1.0 / 60.0];
    [engine touchPhase:2 x:logicalStart.x y:logicalStart.y];
    if (!advance(engine, 120, "actual START gameplay") || !menu(engine, 0, "actual START gameplay") ||
        !capture(engine, geometry, directory, @"02-gameplay", true)) return false;
    if (const char *extra = getenv("SDB_VIEWPORT_EXTRA_FRAMES")) {
        const unsigned frames = unsigned(std::clamp(strtoul(extra, nullptr, 10), 1ul, 3600ul));
        if (!advance(engine, frames, "gameplay after original intro") ||
            !menu(engine, 0, "gameplay after original intro") ||
            !capture(engine, geometry, directory, @"02b-gameplay-later", true)) return false;
    }

    const uint64_t game = diagnostic(engine, "game=", 16);
    const auto baseline = DisplayGeometry::make({480, 320}, 1);
    [engine configureViewport:CGSizeMake(480, 320) displayScale:1 safeArea:CGRectMake(0, 0, 480, 320)];
    if (!check(engine, "resize current game to original") || !menu(engine, 0, "resize retains live gameplay") ||
        diagnostic(engine, "game=", 16) != game ||
        !capture(engine, baseline, directory, @"03-gameplay-original-size", true)) return false;
    [engine configureViewport:variant.size displayScale:variant.scale safeArea:variant.safe];
    if (!advance(engine, 1, "resize current game back") || !menu(engine, 0, "expanded resize retains gameplay") ||
        diagnostic(engine, "game=", 16) != game || ![engine.menuVersion isEqualToString:wantedVersion]) return false;

    if (!pauseState(engine, 0, YES, "native pause available during gameplay")) return false;
    [engine pauseGame];
    if (!advance(engine, 60, "original pause callback") ||
        !pauseState(engine, 3, NO, "original pause menu opened") ||
        !capture(engine, geometry, directory, @"04-pause", false)) return false;

    // Original Pause CONTINUE center (240,130), reflowed through the same
    // safe-menu anchors as START. This exercises the actual guest menu action.
    const auto artworkContinue = geometry.originalToLogical({240, 130});
    const double continueX = safeCenter.x + (artworkContinue.x - artworkCenter.x) *
        std::min(1.0, geometry.safeUIRect.width / 480);
    const double continueY = safeCenter.y + (artworkContinue.y - artworkCenter.y) *
        std::min(1.0, geometry.safeUIRect.height / 320);
    const auto viewContinue = geometry.logicalToView({continueX, continueY});
    const CGPoint logicalContinue = [engine logicalPointForViewPoint:CGPointMake(viewContinue.x, viewContinue.y)];
    if (std::abs(logicalContinue.x - continueX) > 1e-6 || std::abs(logicalContinue.y - continueY) > 1e-6) {
        fprintf(stderr, "FAIL transformed CONTINUE touch\n"); return false;
    }
    [engine touchPhase:0 x:logicalContinue.x y:logicalContinue.y];
    [engine update:1.0 / 60.0];
    [engine touchPhase:2 x:logicalContinue.x y:logicalContinue.y];
    if (!advance(engine, 120, "original pause CONTINUE") ||
        !pauseState(engine, 0, YES, "gameplay resumes through original menu") ||
        diagnostic(engine, "game=", 16) != game ||
        !capture(engine, geometry, directory, @"05-resume", true)) return false;

    [engine setSuspended:YES];
    NSData *save = [NSData dataWithContentsOfFile:[saves stringByAppendingPathComponent:@"savedata.dat"]];
    if (save.length != 256) { fprintf(stderr, "FAIL isolated lifecycle save after resize\n"); return false; }
    printf("PASS %s native raster, opaque frames, full background, actual START, live resize, pause/continue and isolated save: %s\n",
           variant.name, engine.diagnostics.UTF8String);
    return true;
}
} // namespace

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "Usage: ViewportSmoke ORIGINAL_RESOURCE_DIRECTORY TASK_TEMP_OUTPUT [wide|watch|ipad|duo-outer|duo-inner|ipad-window|ipad-landscape]\n");
            return 64;
        }
        NSString *resources = [NSString stringWithUTF8String:argv[1]];
        NSString *output = [[NSString stringWithUTF8String:argv[2]] stringByStandardizingPath];
        if (![output hasPrefix:@"/private/tmp/"] && ![output hasPrefix:@"/tmp/"]) {
            fprintf(stderr, "Use a task-owned temporary output directory.\n"); return 64;
        }
        setenv("SDB_MUTE_AUDIO", "1", 1);
        setvbuf(stdout, nullptr, _IOLBF, 0);
        const Case variants[] = {
            {"wide", CGSizeMake(874, 402), 3, CGRectMake(62, 0, 750, 402)},
            {"watch", CGSizeMake(208, 248), 2, CGRectMake(0, 28, 208, 220)},
            {"ipad", CGSizeMake(1032, 1376), 2, CGRectMake(0, 0, 1032, 1376)},
            {"duo-outer", CGSizeMake(678, 466), 3, CGRectMake(0, 0, 606, 466)},
            {"duo-inner", CGSizeMake(951, 669), 3, CGRectMake(72, 0, 879, 669)},
            {"ipad-window", CGSizeMake(375, 700), 2, CGRectMake(0, 28, 375, 652)},
            {"ipad-landscape", CGSizeMake(1376, 1032), 2, CGRectMake(0, 24, 1376, 988)}
        };
        unsigned completed = 0;
        for (const Case& variant : variants) {
            if (argc > 3 && strcmp(argv[3], variant.name)) continue;
            @autoreleasepool { if (!runCase(variant, resources, output)) return 1; }
            ++completed;
        }
        if (!completed) { fprintf(stderr, "FAIL no matching viewport case\n"); return 64; }
        printf("PASS %u viewport integration cases\n", completed);
    }
    return 0;
}
