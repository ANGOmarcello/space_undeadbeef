//
//  PerformanceEquivalence.mm
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//
// Compare stdout from baseline/current binaries built with this same fixture.
// This exercises actual engine simulation, rendering and saves; it is not a
// benchmark. Hashing, readbacks and checkpoint copies intentionally add work.
#ifndef SDB_ENGINE_SOURCE
#define SDB_ENGINE_SOURCE "../Sources/Legacy/SDBEngine.mm"
#endif
#include SDB_ENGINE_SOURCE
#import <objc/runtime.h>

#include <array>
#include <cstdio>
#include <filesystem>
#include <limits>

namespace {
constexpr unsigned WarmupFrames = 90, WatchFrames = 600, MetalFrames = 300;
constexpr unsigned CheckpointInterval = 30;
constexpr double Step = 1.0 / 60.0;
using Digest = std::array<unsigned char, CC_SHA256_DIGEST_LENGTH>;

struct Fingerprint {
    std::vector<uint8_t> bytes;

    void integer(uint64_t value) {
        for (unsigned shift = 0; shift < 64; shift += 8) bytes.push_back(uint8_t(value >> shift));
    }
    void raw(const void *data, size_t size) {
        if (!size) return;
        const auto *begin = static_cast<const uint8_t *>(data);
        bytes.insert(bytes.end(), begin, begin + size);
    }
    void blob(const void *data, size_t size) { integer(size); raw(data, size); }
    void text(const std::string &value) { blob(value.data(), value.size()); }
    void floating(float value) { uint32_t bits; memcpy(&bits, &value, sizeof(bits)); integer(bits); }
    void floating(double value) { uint64_t bits; memcpy(&bits, &value, sizeof(bits)); integer(bits); }
    Digest digest() const {
        if (bytes.size() > std::numeric_limits<CC_LONG>::max()) abort();
        Digest result;
        CC_SHA256(bytes.data(), CC_LONG(bytes.size()), result.data());
        return result;
    }
};

std::string hexadecimal(const Digest &digest) {
    constexpr char digits[] = "0123456789abcdef";
    std::string result;
    for (unsigned char value : digest) {
        result += digits[value >> 4]; result += digits[value & 15];
    }
    return result;
}

bool check(SDBEngine *engine, const char *stage) {
    if (engine && !engine.failure) return true;
    fprintf(stderr, "FAIL %s: %s\n", stage, engine ? engine.failure.UTF8String : "engine unavailable");
    return false;
}

const Runtime *readRuntime(SDBEngine *engine) {
    // Objective-C supplies the offset for this exact compiled class. Never
    // assume an NSObject header size, reinterpret the object as Runtime, or
    // modify its private unique_ptr/storage. Fail closed if its ABI changes.
    Ivar ivar = class_getInstanceVariable(SDBEngine.class, "_runtime");
    if (!ivar) { fprintf(stderr, "FAIL _runtime ivar unavailable\n"); return nullptr; }
    const ptrdiff_t offset = ivar_getOffset(ivar);
    const size_t instanceSize = class_getInstanceSize(SDBEngine.class);
    const auto *object = static_cast<const uint8_t *>((__bridge const void *)engine);
    if (offset < 0 || size_t(offset) > instanceSize ||
        sizeof(std::unique_ptr<Runtime>) > instanceSize - size_t(offset) ||
        reinterpret_cast<uintptr_t>(object + offset) % alignof(std::unique_ptr<Runtime>)) {
        fprintf(stderr, "FAIL _runtime storage does not fit the actual class layout\n");
        return nullptr;
    }
    const auto *storage = reinterpret_cast<const std::unique_ptr<Runtime> *>(object + offset);
    const Runtime *runtime = storage->get();
    if (!runtime) fprintf(stderr, "FAIL _runtime is empty\n");
    return runtime;
}

Digest stateFingerprint(const Runtime &r) {
    Fingerprint result;
    result.blob(r.cpu.memory.data(), r.cpu.memory.size());
    for (uint32_t value : r.cpu.r) result.integer(value);
    for (bool flag : {r.cpu.n, r.cpu.z, r.cpu.c, r.cpu.v, r.cpu.thumb}) result.integer(flag);
    result.text(r.cpu.fault); result.integer(r.cpu.instructionCount);
    for (uint32_t value : {r.seed, r.heap, r.game, r.sound, r.nextSource}) result.integer(value);
    result.integer(r.allocations.size());
    for (const auto &entry : r.allocations) { result.integer(entry.first); result.integer(entry.second); }
    result.integer(r.freeBlocks.size());
    for (const auto &entry : r.freeBlocks) { result.integer(entry.first); result.integer(entry.second); }
    for (uint64_t value : {r.frames, r.draws, r.audioEvents}) result.integer(value);
    result.floating(r.lastX); result.floating(r.lastY); result.floating(r.steeringY);
    for (bool value : {r.touching, r.watchLayout, r.steeringActive, r.metal}) result.integer(value);
    result.floating(r.geometry.logicalSize.width); result.floating(r.geometry.logicalSize.height);
    result.floating(r.geometry.pixelsPerLogicalUnit);
    result.integer(r.geometry.rasterWidth); result.integer(r.geometry.rasterHeight);
    for (float value : r.matrix.m) result.floating(value);
    result.integer(r.stack.size());
    for (const Matrix &matrix : r.stack) for (float value : matrix.m) result.floating(value);
    for (const Array &array : {r.vertices, r.uvs, r.colors}) {
        result.integer(array.address); result.integer(array.type);
        result.integer(array.size); result.integer(array.stride);
    }
    for (bool value : {r.textured, r.colorArray, r.blend, r.titleDrawn}) result.integer(value);
    for (uint32_t value : {r.texture, r.sourceBlend, r.destBlend, r.textureEnv}) result.integer(value);
    for (float value : r.color) result.floating(value);
    return result.digest();
}

bool imageFingerprint(SDBEngine *engine, Digest &digest) {
    CGImageRef image = engine.frame; // Real CPU publication or completed Metal readback.
    if (!image || CGImageGetBitsPerComponent(image) != 8 || CGImageGetBitsPerPixel(image) != 32) {
        fprintf(stderr, "FAIL frame unavailable or unexpected pixel format\n"); return false;
    }
    const size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    const size_t rowBytes = CGImageGetBytesPerRow(image);
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
    const bool valid = width == size_t(engine.rasterSize.width) && height == size_t(engine.rasterSize.height) &&
        rowBytes >= width * 4 && data && size_t(CFDataGetLength(data)) >= rowBytes * height;
    if (!valid) {
        if (data) CFRelease(data);
        fprintf(stderr, "FAIL frame dimensions or complete pixel storage\n"); return false;
    }
    Fingerprint result;
    result.integer(width); result.integer(height);
    result.integer(CGImageGetBitmapInfo(image));
    // Hash every actual pixel, excluding any implementation-dependent row padding.
    for (size_t row = 0; row < height; ++row)
        result.raw(CFDataGetBytePtr(data) + row * rowBytes, width * 4);
    digest = result.digest();
    CFRelease(data);
    return true;
}

NSString *isolatedSave(const char *argument) {
    NSString *path = [NSString stringWithUTF8String:argument];
    if (!path.isAbsolutePath) return nil;
    std::error_code error;
    const auto resolved = std::filesystem::weakly_canonical(path.fileSystemRepresentation, error);
    if (error) return nil;
    bool temporary = false;
    for (NSString *root in @[NSTemporaryDirectory(), @"/private/tmp"]) {
        const auto canonical = std::filesystem::weakly_canonical(root.fileSystemRepresentation, error);
        if (!error) {
            const std::string prefix = canonical.string() + "/";
            temporary |= resolved.string().compare(0, prefix.size(), prefix) == 0;
        }
    }
    if (!temporary) return nil;
    path = [NSString stringWithUTF8String:resolved.c_str()];
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    NSArray<NSString *> *contents = [files contentsOfDirectoryAtPath:path error:nil];
    return contents && !contents.count ? path : nil;
}

void input(SDBEngine *engine, unsigned index, double offsetX, double offsetY) {
    const unsigned phase = index % 150;
    if (phase == 0) [engine touchPhase:0 x:60 + offsetX y:160 + offsetY];
    if (phase == 60) [engine touchPhase:2 x:60 + offsetX y:160 + offsetY];
    if (phase == 75) [engine touchPhase:0 x:300 + offsetX y:80 + offsetY];
    if (phase >= 75 && phase < 135)
        [engine touchPhase:1 x:300 + offsetX + 120 * std::sin((phase - 75) * M_PI / 60)
                         y:80 + offsetY + (phase - 75) * 2];
    if (phase == 135) [engine touchPhase:2 x:300 + offsetX y:200 + offsetY];
}

void checkpoint(SDBEngine *engine, const Runtime &runtime, const char *phase, unsigned index) {
    printf("checkpoint=%s index=%u state=%s frames=%llu draws=%llu instructions=%llu audio=%llu menu=%ld\n",
           phase, index, hexadecimal(stateFingerprint(runtime)).c_str(),
           static_cast<unsigned long long>(runtime.frames), static_cast<unsigned long long>(runtime.draws),
           static_cast<unsigned long long>(runtime.cpu.instructionCount),
           static_cast<unsigned long long>(runtime.audioEvents), static_cast<long>(engine.gameMenuType));
}

int run(int argc, char **argv) {
    if (argc != 4 || (strcmp(argv[3], "watch") && strcmp(argv[3], "metal"))) {
        fprintf(stderr, "Usage: PerformanceEquivalence RESOURCE_DIRECTORY EMPTY_TEMP_SAVE_DIRECTORY watch|metal\n");
        return 64;
    }
    NSString *save = isolatedSave(argv[2]);
    if (!save) { fprintf(stderr, "FAIL save must be an empty directory inside system temporary storage\n"); return 64; }
    setenv("SDB_SAVE_DIRECTORY", save.UTF8String, 1);
    setenv("SDB_MUTE_AUDIO", "1", 1);
    const bool watch = !strcmp(argv[3], "watch");
    if (watch) setenv("SDB_CPU_RENDERER", "1", 1); else unsetenv("SDB_CPU_RENDERER");
    SDBEngine *engine = [[SDBEngine alloc] initWithResourcePath:[NSString stringWithUTF8String:argv[1]]];
    if (!check(engine, "initialize")) return 1;
    if (!watch && !engine.usesMetalRenderer) {
        SDBMetalRenderer *renderer = [engine valueForKey:@"metalRenderer"];
        if (engine.metalDevice) {
            fprintf(stderr, "FAIL Metal initialization on an available device: %s\n",
                    renderer.failure.UTF8String ?: "renderer did not become ready");
            return 1;
        }
        fprintf(stderr, "SKIP no Metal device\n");
        return 77;
    }
    if (watch) engine.watchLayout = YES;
    const CGSize size = watch ? CGSizeMake(416, 496) : CGSizeMake(480, 320);
    [engine configureViewport:size displayScale:1 safeArea:CGRectMake(0, 0, size.width, size.height)];
    if (!check(engine, "configure")) return 1;
    const Runtime *runtime = readRuntime(engine);
    if (!runtime) return 1;
    const unsigned frames = watch ? WatchFrames : MetalFrames;
    printf("fixture=actual-engine-v1 backend=%s watchLayout=%u raster=%.0fx%.0f warmup=%u frames=%u\n",
           argv[3], unsigned(watch), size.width, size.height, WarmupFrames, frames);
    checkpoint(engine, *runtime, "initial", 0);
    Fingerprint images;
    unsigned imageCount = 0;
    for (unsigned index = 0; index < WarmupFrames; ++index) {
        @autoreleasepool { [engine update:Step]; if (!check(engine, "warm-up")) return 1; }
    }
    checkpoint(engine, *runtime, "warmup", WarmupFrames);
    const double offsetX = (engine.logicalSize.width - 480) / 2;
    const double offsetY = (engine.logicalSize.height - 320) / 2;
    [engine touchPhase:0 x:160 + offsetX y:40 + offsetY];
    [engine update:Step];
    [engine touchPhase:2 x:160 + offsetX y:40 + offsetY];
    if (!check(engine, "Game Start")) return 1;
    checkpoint(engine, *runtime, "start", 0);
    for (unsigned index = 0; index < frames; ++index) {
        @autoreleasepool {
            input(engine, index, offsetX, offsetY);
            [engine advanceSimulation:Step]; [engine renderFrame];
            if (!check(engine, "gameplay")) return 1;
            if (watch || (index + 1) % CheckpointInterval == 0) {
                Digest image;
                if (!imageFingerprint(engine, image)) return 1;
                images.integer(index + 1); images.raw(image.data(), image.size()); ++imageCount;
            }
            if ((index + 1) % CheckpointInterval == 0) checkpoint(engine, *runtime, "frame", index + 1);
        }
    }
    printf("pixels samples=%u sha256=%s\n", imageCount, hexadecimal(images.digest()).c_str());
    [engine setSuspended:YES];
    if (!check(engine, "suspend/save")) return 1;
    checkpoint(engine, *runtime, "suspended", frames);
    NSData *saved = [NSData dataWithContentsOfFile:[save stringByAppendingPathComponent:@"savedata.dat"]];
    if (saved.length != 256) { fprintf(stderr, "FAIL original save is not 256 bytes\n"); return 1; }
    Fingerprint saveBytes; saveBytes.raw(saved.bytes, saved.length);
    printf("save bytes=%lu sha256=%s\n", static_cast<unsigned long>(saved.length),
           hexadecimal(saveBytes.digest()).c_str());
    return 0;
}
} // namespace

int main(int argc, char **argv) { @autoreleasepool { return run(argc, argv); } }
