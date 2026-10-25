// Created by Angelo Cammalleri on 25.10.2026.
// Headless integration smoke test; uses only a caller-owned temporary save folder.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import "SDBEngine.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <cmath>
#include <vector>

static bool check(SDBEngine *engine, const char *stage) {
    if (engine.failure) {
        fprintf(stderr, "FAIL %s: %s\n%s\n", stage, engine.failure.UTF8String, engine.diagnostics.UTF8String);
        return false;
    }
    return true;
}

static uint64_t audioCount(SDBEngine *engine) {
    const char *diagnostics = engine.diagnostics.UTF8String;
    const char *value = strstr(diagnostics, "audio=");
    return value ? strtoull(value + strlen("audio="), nullptr, 10) : 0;
}

static bool audioPolicy(SDBEngine *engine, BOOL sound, BOOL respectsSilent, const char *stage) {
    if (!check(engine, stage)) return false;
    if (engine.soundEnabled != sound || engine.respectsSilentMode != respectsSilent) {
        fprintf(stderr, "FAIL %s: sound=%d respectSilent=%d, expected %d/%d\n", stage,
                engine.soundEnabled, engine.respectsSilentMode, sound, respectsSilent);
        return false;
    }
    printf("PASS %s: sound=%d respectSilent=%d\n", stage, sound, respectsSilent);
    return true;
}

static bool storedAudioPreference(NSString *saves, NSString *key, BOOL expected) {
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:
        [saves stringByAppendingPathComponent:@"audio-preferences.plist"]];
    NSNumber *value = preferences[key];
    if (!value || value.boolValue != expected) {
        fprintf(stderr, "FAIL isolated preference %s: expected %d\n", key.UTF8String, expected);
        return false;
    }
    return true;
}

static NSString *frameHash(SDBEngine *engine) {
    if (!engine.frame) return @"missing";
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(engine.frame));
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(CFDataGetBytePtr(data), (CC_LONG)CFDataGetLength(data), digest);
    CFRelease(data);
    NSMutableString *result = [NSMutableString string];
    for (unsigned char value : digest) [result appendFormat:@"%02x", value];
    return result;
}

static bool snapshot(SDBEngine *engine, NSString *directory, NSString *name) {
    if (!engine.frame) { fprintf(stderr, "FAIL missing frame\n"); return false; }
    NSURL *url = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]]];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, nullptr);
    if (!destination) return false;
    CGImageDestinationAddImage(destination, engine.frame, nullptr);
    bool succeeded = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    printf("SNAPSHOT %s %s\n", url.path.UTF8String, frameHash(engine).UTF8String);
    return succeeded;
}

static bool advance(SDBEngine *engine, unsigned frames, const char *stage, bool report = true) {
    for (unsigned index = 0; index < frames; ++index) {
        @autoreleasepool {
            [engine update:1.0 / 60.0];
            if (!check(engine, stage)) return false;
        }
    }
    if (report) {
        printf("PASS %s: %s\n", stage, engine.diagnostics.UTF8String);
        fflush(stdout);
    }
    return true;
}

static bool activeGameplay(SDBEngine *engine, NSString *directory, unsigned frames) {
    // These are ordinary landscape pointer events. No guest state, health,
    // score, scenario, or instruction stream is changed by this driver.
    unsigned advanced = 0, cycle = 0;
    auto step = [&](const char *stage) {
        if (!advance(engine, 1, stage, false)) return false;
        ++advanced;
        return true;
    };
    while (advanced < frames) {
        bool capture = cycle == 0 || cycle == 2 || cycle == 5 || cycle == 9;
        NSString *prefix = [NSString stringWithFormat:@"active-%02u", cycle];
        [engine touchPhase:0 x:60 y:160];
        for (unsigned index = 0; index < 60 && advanced < frames; ++index)
            if (!step("active ship hold")) return false;
        if (capture && !snapshot(engine, directory, [prefix stringByAppendingString:@"-charge-held"])) return false;
        [engine touchPhase:2 x:60 y:160];
        for (unsigned index = 0; index < 15 && advanced < frames; ++index)
            if (!step("active charged shot release")) return false;
        if (capture && !snapshot(engine, directory, [prefix stringByAppendingString:@"-charge-released"])) return false;

        [engine touchPhase:0 x:300 y:80];
        for (unsigned index = 1; index <= 60 && advanced < frames; ++index) {
            double progress = index <= 30 ? index / 30.0 : (index - 30) / 30.0;
            double x = index <= 30 ? 300 + 140 * progress : 440 - 140 * progress;
            double y = index <= 30 ? 80 + 80 * progress : 160 + 80 * progress;
            [engine touchPhase:1 x:x y:y];
            if (!step("active enemy lock-on scan")) return false;
        }
        if (capture && !snapshot(engine, directory, [prefix stringByAppendingString:@"-scan-held"])) return false;
        [engine touchPhase:2 x:300 y:240];
        for (unsigned index = 0; index < 15 && advanced < frames; ++index)
            if (!step("active missiles release")) return false;
        if (capture && !snapshot(engine, directory, [prefix stringByAppendingString:@"-scan-released"])) return false;

        [engine touchPhase:0 x:60 y:160];
        for (unsigned index = 1; index <= 60 && advanced < frames; ++index) {
            double y = 160 + 80 * std::sin(index * 2 * M_PI / 60);
            [engine touchPhase:1 x:60 y:y];
            if (!step("active vertical ship drag")) return false;
        }
        [engine touchPhase:3 x:60 y:160];
        for (unsigned index = 0; index < 30 && advanced < frames; ++index)
            if (!step("active recovery")) return false;

        // A real tap in the game's Continue-button location also acts as a
        // normal target tap during play. This permits recovery if the guest's
        // ordinary Game Over menu appeared; it grants no invulnerability.
        if ((cycle % 3) == 2 && advanced < frames) {
            [engine touchPhase:0 x:240 y:130];
            if (!step("active continue-location tap")) return false;
            [engine touchPhase:2 x:240 y:130];
        }
        printf("PASS active cycle=%u updates=%u audio=%llu: %s\n", cycle, advanced,
               (unsigned long long)audioCount(engine), engine.diagnostics.UTF8String);
        fflush(stdout);
        ++cycle;
    }
    [engine touchPhase:3 x:0 y:0];
    return check(engine, "active input completion");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "Usage: RuntimeSmoke RESOURCE_DIRECTORY TEMP_OUTPUT_DIRECTORY [tapX tapY [gameplayFrames]]\n");
            return 64;
        }
        NSString *resources = [NSString stringWithUTF8String:argv[1]];
        NSString *output = [[NSString stringWithUTF8String:argv[2]] stringByStandardizingPath];
        if (![output hasPrefix:@"/private/tmp/"] && ![output hasPrefix:@"/tmp/"]) {
            fprintf(stderr, "Use a task-owned temporary output directory.\n");
            return 64;
        }
        [NSFileManager.defaultManager createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *saves = [output stringByAppendingPathComponent:@"saves"];
        bool freshPreferences = ![NSFileManager.defaultManager fileExistsAtPath:
            [saves stringByAppendingPathComponent:@"audio-preferences.plist"]];
        setenv("SDB_SAVE_DIRECTORY", saves.UTF8String, 1);
        setenv("SDB_MUTE_AUDIO", "1", 1);
        bool soundTest = getenv("SDB_SMOKE_SOUND") != nullptr;
        SDBEngine *engine = [[SDBEngine alloc] initWithResourcePath:resources];
        if (!check(engine, "initialize")) return 1;
        if (freshPreferences && !audioPolicy(engine, YES, YES, "new-install audio defaults")) return 1;
        if (soundTest) {
            engine.respectsSilentMode = NO;
            if (!storedAudioPreference(saves, @"audio.respectsSilentMode", NO)) return 1;
            engine = nil;
            engine = [[SDBEngine alloc] initWithResourcePath:resources];
            if (!audioPolicy(engine, YES, NO, "silent-policy OFF persistence")) return 1;
        }
        printf("PASS initialize: %s\n", engine.diagnostics.UTF8String);
        if (!snapshot(engine, output, @"00-initial")) return 1;
        if (!advance(engine, 120, "title warmup")) return 1;
        if (!snapshot(engine, output, @"01-title")) return 1;
        NSString *titleHash = frameHash(engine);
        if (soundTest) {
            [engine touchPhase:0 x:160 y:120];
            [engine update:1.0 / 60.0];
            [engine touchPhase:2 x:160 y:120];
            if (!advance(engine, 120, "Options menu")) return 1;
            if (!snapshot(engine, output, @"01a-options")) return 1;
            if (argc >= 5) {
                [engine touchPhase:0 x:300 y:150];
                [engine update:1.0 / 60.0];
                [engine touchPhase:2 x:300 y:150];
                if (!advance(engine, 60, "explicit Sound OFF")) return 1;
                if (!audioPolicy(engine, NO, NO, "original Options OFF")) return 1;
                if (!storedAudioPreference(saves, @"audio.soundEnabled", NO)) return 1;
                if (!snapshot(engine, output, @"01b-sound-off")) return 1;
                // Recreate before SAVE-EXIT: the explicit OFF choice must persist
                // immediately through native preferences, independently of saves.
                engine = nil;
                engine = [[SDBEngine alloc] initWithResourcePath:resources];
                if (!audioPolicy(engine, NO, NO, "explicit OFF before SAVE-EXIT relaunch")) return 1;
                if (!advance(engine, 120, "OFF relaunch title")) return 1;
                [engine touchPhase:0 x:160 y:120];
                [engine update:1.0 / 60.0];
                [engine touchPhase:2 x:160 y:120];
                if (!advance(engine, 120, "OFF relaunch Options")) return 1;
                if (!snapshot(engine, output, @"01c-off-after-relaunch")) return 1;
                [engine touchPhase:0 x:240 y:280];
                [engine update:1.0 / 60.0];
                [engine touchPhase:2 x:240 y:280];
                if (!advance(engine, 120, "OFF SAVE-EXIT")) return 1;
                NSData *offSave = [NSData dataWithContentsOfFile:[saves stringByAppendingPathComponent:@"savedata.dat"]];
                if (offSave.length != 256 || ((const uint8_t *)offSave.bytes)[20] != 0) {
                    fprintf(stderr, "FAIL Sound OFF did not reach original savedata\n");
                    return 1;
                }
                engine = nil;
                engine = [[SDBEngine alloc] initWithResourcePath:resources];
                if (!audioPolicy(engine, NO, NO, "OFF preferences and savedata relaunch")) return 1;
                if (!advance(engine, 120, "OFF saved title")) return 1;
                [engine touchPhase:0 x:160 y:120];
                [engine update:1.0 / 60.0];
                [engine touchPhase:2 x:160 y:120];
                if (!advance(engine, 120, "Options for Sound ON")) return 1;
                [engine touchPhase:0 x:180 y:150];
                [engine update:1.0 / 60.0];
                [engine touchPhase:2 x:180 y:150];
                if (!advance(engine, 60, "Sound ON")) return 1;
                if (!audioPolicy(engine, YES, NO, "Sound ON retains silent-policy OFF")) return 1;
                if (!storedAudioPreference(saves, @"audio.soundEnabled", YES)) return 1;
                if (!snapshot(engine, output, @"01d-sound-on")) return 1;
                [engine touchPhase:0 x:240 y:280];
                [engine update:1.0 / 60.0];
                [engine touchPhase:2 x:240 y:280];
                if (!advance(engine, 120, "Options SAVE-EXIT")) return 1;
                NSData *settingsSave = [NSData dataWithContentsOfFile:[saves stringByAppendingPathComponent:@"savedata.dat"]];
                if (settingsSave.length != 256 || ((const uint8_t *)settingsSave.bytes)[20] != 1) {
                    fprintf(stderr, "FAIL Sound ON did not persist through original SAVE-EXIT\n");
                    return 1;
                }
                printf("PASS original Options OFF/ON choices persist immediately and in SAVE-EXIT.\n");
                engine = nil;
                engine = [[SDBEngine alloc] initWithResourcePath:resources];
                if (!audioPolicy(engine, YES, NO, "ON saved-data relaunch retains silent-policy OFF")) return 1;
                engine.respectsSilentMode = YES;
                if (!storedAudioPreference(saves, @"audio.respectsSilentMode", YES)) return 1;
                engine = nil;
                engine = [[SDBEngine alloc] initWithResourcePath:resources];
                if (!audioPolicy(engine, YES, YES, "silent-policy ON persistence")) return 1;
                if (!advance(engine, 120, "audio-policy final title")) return 1;
                if (!snapshot(engine, output, @"01e-title-after-options")) return 1;
                titleHash = frameHash(engine);
            }
        }
        if (argc < 5) {
            printf("PASS preview run; provide tap coordinates to continue gameplay.\n");
            return 0;
        }
        double tapX = strtod(argv[3], nullptr), tapY = strtod(argv[4], nullptr);
        [engine touchPhase:0 x:tapX y:tapY];
        if (!check(engine, "title touch begin")) return 1;
        if (!advance(engine, 1, "title touch held")) return 1;
        [engine touchPhase:2 x:tapX y:tapY];
        if (!check(engine, "title touch end")) return 1;
        if (!advance(engine, 120, "after title tap")) return 1;
        if (!snapshot(engine, output, @"02-after-title-tap")) return 1;
        if ([titleHash isEqualToString:frameHash(engine)]) {
            fprintf(stderr, "FAIL title tap did not change the rendered frame\n");
            return 1;
        }
        bool activeTest = getenv("SDB_SMOKE_ACTIVE") != nullptr;
        unsigned gameplayFrames = argc > 5 ? unsigned(strtoul(argv[5], nullptr, 10)) : (activeTest ? 3600 : 480);
        if (activeTest) {
            if (!activeGameplay(engine, output, std::max(2400u, gameplayFrames))) return 1;
        } else if (!advance(engine, gameplayFrames, "gameplay")) return 1;
        if (!snapshot(engine, output, @"03-gameplay")) return 1;
        if (soundTest && audioCount(engine) == 0) {
            fprintf(stderr, "FAIL Sound ON produced no guest audio play events during gameplay\n");
            return 1;
        }
        // Exercise a real drag and cancellation through the host's inverse mapping.
        [engine touchPhase:0 x:240 y:160];
        for (unsigned index = 1; index <= 30; ++index) {
            [engine touchPhase:1 x:240 + index * 2 y:160 - index];
            if (!advance(engine, 1, "drag", false)) return 1;
        }
        [engine touchPhase:3 x:300 y:130];
        if (!check(engine, "drag cancellation")) return 1;
        [engine setSuspended:YES];
        if (!check(engine, "save on suspension")) return 1;
        NSData *save = [NSData dataWithContentsOfFile:[saves stringByAppendingPathComponent:@"savedata.dat"]];
        uint32_t magic = 0, size = 0;
        if (save.length >= 12) { memcpy(&magic, save.bytes, 4); memcpy(&size, (const uint8_t *)save.bytes + 8, 4); }
        if (save.length != 256 || magic != 0x30485350 || size != 256) {
            fprintf(stderr, "FAIL savedata format: bytes=%lu magic=%08x size=%u\n", (unsigned long)save.length, magic, size);
            return 1;
        }
        [engine setSuspended:NO];
        if (!advance(engine, 30, "resume")) return 1;
        engine = nil;
        engine = [[SDBEngine alloc] initWithResourcePath:resources];
        if (!check(engine, "reload saved game")) return 1;
        if (soundTest && !audioPolicy(engine, YES, YES, "final audio-policy relaunch")) return 1;
        if (!advance(engine, 120, "saved-data relaunch")) return 1;
        if (!snapshot(engine, output, @"04-relaunch")) return 1;
        [engine touchPhase:0 x:160 y:80];
        [engine update:1.0 / 60.0];
        [engine touchPhase:2 x:160 y:80];
        if (!advance(engine, 120, "continue saved checkpoint")) return 1;
        if (!snapshot(engine, output, @"05-continue")) return 1;
        if (soundTest && audioCount(engine) == 0) {
            fprintf(stderr, "FAIL reloaded Sound ON produced no guest audio play events\n");
            return 1;
        }
        printf("PASS guest launch, title transition, gameplay, drag, cancellation, atomic save format, resume, saved-data relaunch, and Continue.\n");
    }
    return 0;
}
