//
//  RendererTests.mm
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//

// Include the engine once to exercise its actual private CPU triangle renderer.
// The test script must not also compile SDBEngine.mm as another translation unit.
// No SDBEngine instance, app, save directory, or user preferences are created.
#include "../Sources/Legacy/SDBEngine.mm"
#include <cstdio>

namespace {
constexpr unsigned RasterWidth = 80, RasterHeight = 40;
constexpr uint32_t FixtureTexture = 7;
constexpr double MaximumByteError = 1;

bool require(bool condition, const char *message) {
    if (!condition) fprintf(stderr, "FAIL %s\n", message);
    return condition;
}

bool loadTexture(NSString *resources, NSString *name, Texture& texture) {
    NSURL *url = [NSURL fileURLWithPath:[resources stringByAppendingPathComponent:name]];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, nullptr) : nullptr;
    if (source) CFRelease(source);
    if (!image) { fprintf(stderr, "FAIL decode %s\n", name.UTF8String); return false; }
    texture.width = int(CGImageGetWidth(image));
    texture.height = int(CGImageGetHeight(image));
    texture.pixels.resize(size_t(texture.width) * texture.height * 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(texture.pixels.data(), texture.width, texture.height,
        8, texture.width * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) { CGImageRelease(image); return require(false, "texture decode context"); }
    CGContextDrawImage(context, CGRectMake(0, 0, texture.width, texture.height), image);
    CGContextRelease(context);
    CGImageRelease(image);
    for (size_t p = 0; p < texture.pixels.size(); p += 4) if (texture.pixels[p + 3])
        for (int channel = 0; channel < 3; ++channel)
            texture.pixels[p + channel] = uint8_t(std::min(255u,
                unsigned(texture.pixels[p + channel]) * 255 / texture.pixels[p + 3]));
    return true;
}

std::vector<Vertex> quad(const Runtime& runtime, float u0 = 0, float v0 = 0,
                         float u1 = 1, float v1 = 1, float offsetX = 0) {
    const float width = float(runtime.geometry.logicalSize.width);
    const float height = float(runtime.geometry.logicalSize.height);
    return {{offsetX, 0, u0, v0, 1, 1, 1, 1},
        {width + offsetX, 0, u1, v0, 1, 1, 1, 1},
        {offsetX, height, u0, v1, 1, 1, 1, 1},
        {offsetX, height, u0, v1, 1, 1, 1, 1},
        {width + offsetX, 0, u1, v0, 1, 1, 1, 1},
        {width + offsetX, height, u1, v1, 1, 1, 1, 1}};
}

bool renderCPU(Runtime& runtime, const Texture& texture, const std::vector<Vertex>& vertices) {
    runtime.pixels.assign(RasterWidth * RasterHeight * 4, 0);
    // A blue background exposes the retained black shadow, which is invisible
    // over black. The foreground still uses the original straight-alpha blend.
    for (size_t p = 0; p < runtime.pixels.size(); p += 4)
        runtime.pixels[p + 2] = runtime.pixels[p + 3] = 255;
    runtime.textures[FixtureTexture] = texture;
    runtime.texture = FixtureTexture;
    runtime.textured = true;
    runtime.blend = true;
    runtime.textureEnv = 0x1e01;
    runtime.sourceBlend = 0x302;
    runtime.destBlend = 0x303;
    for (size_t i = 0; i < vertices.size(); i += 3)
        runtime.triangle(vertices[i], vertices[i + 1], vertices[i + 2]);
    bool visible = false;
    for (size_t p = 0; p < runtime.pixels.size(); p += 4) {
        if (!require(runtime.pixels[p + 3] == 255, "CPU frame remains opaque")) return false;
        visible |= runtime.pixels[p] || runtime.pixels[p + 1] || runtime.pixels[p + 2] != 255;
    }
    return require(visible, "fixture actually changes the background");
}

bool pixel(const Runtime& runtime, unsigned x, unsigned y, int red, int green, int blue) {
    const uint8_t *p = runtime.pixels.data() + 4 * (y * RasterWidth + x);
    return require(std::abs(int(p[0]) - red) <= MaximumByteError &&
        std::abs(int(p[1]) - green) <= MaximumByteError &&
        std::abs(int(p[2]) - blue) <= MaximumByteError, "CPU coverage oracle");
}

bool compareGPU(Runtime& runtime, SDBMetalRenderer *gpu, const char *name,
                const Texture& texture, const std::vector<Vertex>& vertices,
                bool unalignedVertexRange = false) {
    if (!gpu.supported) return true;
    if (![gpu setTexture:FixtureTexture rgba:texture.pixels.data() byteLength:texture.pixels.size()
                  width:texture.width height:texture.height]) {
        fprintf(stderr, "FAIL upload %s: %s\n", name, gpu.failure.UTF8String); return false;
    }
    auto background = quad(runtime);
    std::vector<SDBMetalVertex> metal;
    for (const Vertex& v : background) metal.push_back({v.x, v.y, 0, 0, 0, 0, 1, 1});
    // Draw ranges need not begin at a buffer index divisible by three.
    // A skipped vertex catches per-triangle bounds indexed from buffer zero.
    if (unalignedVertexRange) metal.push_back({0, 0, 0, 0, 0, 0, 0, 0});
    const uint32_t firstGlyphVertex = uint32_t(metal.size());
    for (const Vertex& v : vertices) metal.push_back({v.x, v.y, v.u, v.v, v.r, v.g, v.b, v.a});
    const SDBMetalDraw draws[] = {
        {0, uint32_t(background.size()), 0, 0, 0x2100, 0, 1, 0, 0, 0, 0},
        {firstGlyphVertex, uint32_t(vertices.size()), FixtureTexture, 1, 0x1e01,
            1, 0x302, 0x303, 0, texture.distanceField, uint32_t(texture.glyphAtlas)}
    };
    if (![gpu renderVertices:metal.data() vertexCount:metal.size() draws:draws drawCount:2
        logicalSize:CGSizeMake(runtime.geometry.logicalSize.width, runtime.geometry.logicalSize.height)
        pixelWidth:RasterWidth pixelHeight:RasterHeight]) {
        fprintf(stderr, "FAIL submit %s: %s\n", name, gpu.failure.UTF8String ?: "GPU queue busy"); return false;
    }
    CGImageRef image = [gpu copyCurrentFrame];
    if (!require(image != nullptr, "GPU capture exists")) return false;
    const bool dimensions = CGImageGetWidth(image) == RasterWidth && CGImageGetHeight(image) == RasterHeight &&
        CGImageGetBitsPerComponent(image) == 8 && CGImageGetBitsPerPixel(image) == 32;
    if (!require(dimensions, "GPU capture dimensions and format")) { CGImageRelease(image); return false; }
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
    if (!require(data && size_t(CFDataGetLength(data)) >= CGImageGetBytesPerRow(image) * RasterHeight,
                 "GPU pixel data exists")) { if (data) CFRelease(data); CGImageRelease(image); return false; }
    const uint8_t *pixels = CFDataGetBytePtr(data);
    unsigned maximum = 0;
    uint64_t sum = 0;
    bool opaque = true;
    for (unsigned y = 0; y < RasterHeight; ++y) for (unsigned x = 0; x < RasterWidth; ++x) {
        const uint8_t *gpuPixel = pixels + y * CGImageGetBytesPerRow(image) + x * 4;
        opaque &= gpuPixel[3] == 255;
        for (unsigned channel = 0; channel < 3; ++channel) {
            const unsigned difference = unsigned(std::abs(int(runtime.pixels[4 * (y * RasterWidth + x) + channel]) -
                                                         int(gpuPixel[channel])));
            maximum = std::max(maximum, difference); sum += difference;
        }
    }
    CFRelease(data);
    CGImageRelease(image);
    printf("%s %s CPU/Metal max=%u mean=%.6f bytes\n", maximum <= MaximumByteError && opaque ? "PASS" : "FAIL",
           name, maximum, double(sum) / (RasterWidth * RasterHeight * 3));
    return require(opaque && maximum <= MaximumByteError, "CPU/Metal parity within one byte");
}

bool glyphAtlasIsolation(Runtime& runtime, SDBMetalRenderer *gpu) {
    // A magnified glyph has a transparent one-texel border. Opaque adjacent
    // cells make any cross-cell linear sampling appear as a bright hairline.
    Texture atlas;
    atlas.width = 128; atlas.height = 64;
    atlas.pixels.assign(size_t(atlas.width) * atlas.height * 4, 255);
    constexpr unsigned CellSide = 8, Column = 5, Row = 3;
    for (unsigned y = 0; y < CellSide; ++y) for (unsigned x = 0; x < CellSide; ++x) {
        const bool ink = x >= 2 && x < 6 && y >= 2 && y < 6;
        atlas.pixels[4 * ((Row * CellSide + y) * atlas.width + Column * CellSide + x) + 3] = ink ? 255 : 0;
    }
    const auto vertices = quad(runtime, Column / 16.f, Row / 8.f, (Column + 1) / 16.f,
                               (Row + 1) / 8.f, float(.25 / runtime.geometry.pixelsPerLogicalUnit));
    if (!renderCPU(runtime, atlas, vertices) ||
        !require(runtime.pixels[4 * ((RasterHeight / 2) * RasterWidth)] > MaximumByteError,
                 "unisolated control exposes neighboring glyph-cell bleed") ||
        !compareGPU(runtime, gpu, "glyph atlas unisolated bleed control", atlas, vertices)) return false;

    atlas.glyphAtlas = true;
    if (!renderCPU(runtime, atlas, vertices)) return false;
    for (unsigned y = 0; y < RasterHeight; ++y) for (unsigned x = 0; x < RasterWidth; ++x) {
        if (x && y && x + 1 < RasterWidth && y + 1 < RasterHeight) continue;
        const uint8_t *p = runtime.pixels.data() + 4 * (y * RasterWidth + x);
        if (p[0] || p[1] || p[2] != 255) {
            fprintf(stderr, "FAIL isolated glyph border at %u,%u: RGB=%u,%u,%u\n",
                    x, y, unsigned(p[0]), unsigned(p[1]), unsigned(p[2]));
            return false;
        }
    }
    return compareGPU(runtime, gpu, "glyph atlas isolated fractional magnification, firstVertex7", atlas, vertices, true);
}

struct GPUFixture {
    CGSize logicalSize = CGSizeMake(RasterWidth, RasterHeight);
    std::vector<SDBMetalVertex> vertices;
    std::vector<SDBMetalDraw> draws;

    void append(const std::vector<Vertex>& points, SDBMetalDraw state, bool gap) {
        if (gap && !vertices.empty()) vertices.push_back({});
        state.firstVertex = uint32_t(vertices.size());
        state.vertexCount = uint32_t(points.size());
        for (const Vertex& v : points) vertices.push_back({v.x,v.y,v.u,v.v,v.r,v.g,v.b,v.a});
        draws.push_back(state);
    }
};

bool captureFixture(SDBMetalRenderer *gpu, const GPUFixture& fixture,
                    std::vector<uint8_t>& bytes, NSUInteger expectedDraws,
                    NSUInteger expectedPipelineBindings = 0) {
    if (![gpu renderVertices:fixture.vertices.data() vertexCount:fixture.vertices.size()
        draws:fixture.draws.data() drawCount:fixture.draws.size()
        logicalSize:fixture.logicalSize pixelWidth:RasterWidth pixelHeight:RasterHeight]) {
        fprintf(stderr, "FAIL batch fixture submit: %s\n", gpu.failure.UTF8String ?: "GPU queue busy");
        return false;
    }
    if (!require([[gpu valueForKey:@"lastEncodedDrawCount"] unsignedIntegerValue] == expectedDraws,
                 "native draw count matches ordered batch boundaries") ||
        (expectedPipelineBindings && !require([[gpu valueForKey:@"lastPipelineBindingCount"] unsignedIntegerValue] ==
            expectedPipelineBindings, "unchanged native pipeline is not rebound"))) return false;
    CGImageRef image = [gpu copyCurrentFrame];
    if (!require(image != nullptr, "batch fixture GPU snapshot exists")) return false;
    const bool format = CGImageGetWidth(image) == RasterWidth && CGImageGetHeight(image) == RasterHeight &&
        CGImageGetBitsPerComponent(image) == 8 && CGImageGetBitsPerPixel(image) == 32;
    if (!require(format, "batch fixture snapshot format")) { CGImageRelease(image); return false; }
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
    if (!require(data && CFDataGetLength(data) >= CFIndex(CGImageGetBytesPerRow(image) * RasterHeight),
                 "batch fixture GPU data exists")) {
        if (data) CFRelease(data);
        CGImageRelease(image);
        return false;
    }
    bytes.resize(RasterWidth * RasterHeight * 4);
    for (unsigned y = 0; y < RasterHeight; ++y)
        std::memcpy(bytes.data() + size_t(y) * RasterWidth * 4,
                    CFDataGetBytePtr(data) + size_t(y) * CGImageGetBytesPerRow(image), RasterWidth * 4);
    CFRelease(data);
    CGImageRelease(image);
    return true;
}

bool batchParity(Runtime& runtime, SDBMetalRenderer *gpu, const char *name,
                 const Texture& texture, bool glyphs, uint32_t destinationBlend = 0x303) {
    if (!gpu.supported) return true;
    if (![gpu setTexture:FixtureTexture rgba:texture.pixels.data() byteLength:texture.pixels.size()
        width:texture.width height:texture.height]) return require(false, "batch fixture texture upload");
    GPUFixture packed, separate;
    packed.logicalSize = separate.logicalSize = CGSizeMake(runtime.geometry.logicalSize.width, runtime.geometry.logicalSize.height);
    auto background = quad(runtime);
    for (Vertex& v : background) { v.r = v.g = 0; v.b = v.a = 1; }
    const SDBMetalDraw solid = {0,0,0,0,0x2100,0,1,0,0,0,0};
    const SDBMetalDraw state = {0,0,FixtureTexture,1,0x2100,1,0x302,destinationBlend,0,
        texture.distanceField, texture.glyphAtlas};
    packed.append(background, solid, false);
    separate.append(background, solid, false);
    // Both layouts start the first sprite at vertex seven. Only the control
    // inserts further unused vertices, preventing native merging without
    // changing positions, per-triangle glyph cells, state or primitive order.
    packed.vertices.push_back({});
    constexpr unsigned SpriteCount = 24;
    for (unsigned i = 0; i < SpriteCount; ++i) {
        const float u0 = glyphs ? float((i + 48) % 16) / 16 : 0;
        const float v0 = glyphs ? float((i + 48) / 16) / 8 : 0;
        auto points = quad(runtime, u0, v0, glyphs ? u0 + 1.f/16 : 1,
            glyphs ? v0 + 1.f/8 : 1);
        for (Vertex& v : points) {
            v.x = v.x * .3f + float(i % 6) * float(packed.logicalSize.width) / 7.f;
            v.y = v.y * .6f + float(i / 6) * float(packed.logicalSize.height) / 7.f;
            v.r = .25f + float(i % 3) * .3f;
            v.g = .4f + float(i % 2) * .4f;
            v.a = .35f + float(i % 4) * .15f;
        }
        packed.append(points, state, false);
        separate.append(points, state, true);
    }
    std::vector<uint8_t> combined, control;
    if (!captureFixture(gpu, packed, combined, 2, 2) ||
        !captureFixture(gpu, separate, control, SpriteCount + 1, 2) ||
        !require(combined == control, "batched and separate GPU pixels are byte-identical")) return false;
    printf("PASS %s: %u ordered sprite draws -> 1, byte-identical GPU pixels, unaligned vertex seven\n",
           name, SpriteCount);
    return true;
}

bool batchStateBoundaries(Runtime& runtime, SDBMetalRenderer *gpu, const Texture& texture) {
    if (!gpu.supported) return true;
    if (![gpu setTexture:FixtureTexture rgba:texture.pixels.data() byteLength:texture.pixels.size()
        width:texture.width height:texture.height] ||
        ![gpu setTexture:FixtureTexture + 1 rgba:texture.pixels.data() byteLength:texture.pixels.size()
        width:texture.width height:texture.height]) return require(false, "boundary textures upload");
    const SDBMetalDraw base = {0,0,FixtureTexture,1,0x2100,1,0x302,0x303,0,0,0};
    const auto background = quad(runtime);
    auto points = quad(runtime, .1f, .1f, .9f, .9f);
    for (Vertex& v : points) { v.r=.3f;v.g=.5f;v.b=.7f;v.a=.6f; }
    for (unsigned field = 0; field < 9; ++field) {
        SDBMetalDraw changed = base;
        switch (field) {
            case 0: changed.textureID = FixtureTexture + 1; break;
            case 1: changed.textured = 0; break;
            case 2: changed.textureEnv = 0x1e01; break;
            case 3: changed.blend = 0; break;
            case 4: changed.sourceBlend = 1; break;
            case 5: changed.destBlend = 1; break;
            case 6: changed.nearest = 1; break;
            case 7: changed.distanceField = 1; break;
            case 8: changed.glyphAtlas = 1; break;
        }
        GPUFixture packed, separate;
        packed.logicalSize = separate.logicalSize = CGSizeMake(runtime.geometry.logicalSize.width, runtime.geometry.logicalSize.height);
        for (GPUFixture *fixture : {&packed, &separate}) {
            fixture->append(background, {0,0,0,0,0x2100,0,1,0,0,0,0}, false);
            fixture->append(points, base, fixture == &separate);
            fixture->append(points, changed, fixture == &separate);
            fixture->append(points, base, fixture == &separate);
        }
        std::vector<uint8_t> combined, control;
        if (!captureFixture(gpu, packed, combined, 4) || !captureFixture(gpu, separate, control, 4) ||
            !require(combined == control, "every original state boundary preserves ordered GPU pixels")) return false;
    }
    // A gap, overlap, reversed range, or zero-length range is not a contiguous
    // triangle sequence. It must never cause an unrelated triangle to render.
    for (unsigned boundary = 0; boundary < 4; ++boundary) {
        GPUFixture fixture;
        fixture.logicalSize = CGSizeMake(runtime.geometry.logicalSize.width, runtime.geometry.logicalSize.height);
        fixture.append(points, base, false);
        fixture.append(points, base, true);
        if (boundary == 1) fixture.draws[1].firstVertex = fixture.draws[0].firstVertex;
        if (boundary == 2) std::swap(fixture.draws[0], fixture.draws[1]);
        if (boundary == 3) fixture.draws.insert(fixture.draws.begin() + 1,
            SDBMetalDraw{6,0,FixtureTexture,1,0x2100,1,0x302,0x303,0,0,0});
        std::vector<uint8_t> bytes;
        if (!captureFixture(gpu, fixture, bytes, 2, 1)) return false;
    }
    // Invalid trailing records must be rejected before a valid prefix is
    // encoded, even if the prefix could otherwise be merged.
    GPUFixture valid;
    valid.logicalSize = CGSizeMake(runtime.geometry.logicalSize.width, runtime.geometry.logicalSize.height);
    valid.append(points, base, false);
    valid.append(points, base, false);
    std::vector<uint8_t> before;
    if (!captureFixture(gpu, valid, before, 1, 1)) return false;
    for (unsigned invalid = 0; invalid < 7; ++invalid) {
        GPUFixture bad = valid;
        switch (invalid) {
            case 0: bad.draws.back().firstVertex = uint32_t(bad.vertices.size() + 1); break;
            case 1: bad.draws.back().vertexCount = 4; break;
            case 2: bad.draws.back().textureID = 9999; break;
            case 3: bad.draws.back().textureEnv = 9999; break;
            case 4: bad.draws.back().sourceBlend = 9999; break;
            case 5:
                bad.draws.front().blend = 0;
                bad.draws.back().sourceBlend = bad.draws.back().destBlend = UINT32_MAX;
                break;
            case 6:
                bad.draws.back().vertexCount = 0;
                bad.draws.back().sourceBlend = 9999;
                break;
        }
        if (!require(![gpu renderVertices:bad.vertices.data() vertexCount:bad.vertices.size()
                draws:bad.draws.data() drawCount:bad.draws.size() logicalSize:bad.logicalSize
                pixelWidth:RasterWidth pixelHeight:RasterHeight] && gpu.failure != nil,
                "invalid trailing draw fails before any encoding") ||
            !require([[gpu valueForKey:@"lastEncodedDrawCount"] unsignedIntegerValue] == 1,
                "rejected frame retains prior successful submission diagnostics")) return false;
        std::vector<uint8_t> recovered;
        if (!captureFixture(gpu, valid, recovered, 1, 1) ||
            !require(recovered == before, "valid rendering recovers after rejected input")) return false;
    }
    printf("PASS nine state boundaries, gaps/overlaps/reversed/empty ranges, and seven rejected trailing draws\n");
    return true;
}

bool snapshotBytes(CGImageRef image, std::vector<uint8_t>& pixels) {
    if (!require(image && CGImageGetWidth(image) == RasterWidth && CGImageGetHeight(image) == RasterHeight &&
            CGImageGetBitsPerPixel(image) == 32, "trim snapshot format remains RGBA8")) return false;
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
    if (!require(data && CFDataGetLength(data) >= CFIndex(CGImageGetBytesPerRow(image) * RasterHeight),
                 "trim snapshot data exists")) {
        if (data) CFRelease(data);
        return false;
    }
    pixels.resize(RasterWidth * RasterHeight * 4);
    for (unsigned y = 0; y < RasterHeight; ++y)
        std::memcpy(pixels.data() + size_t(y) * RasterWidth * 4,
            CFDataGetBytePtr(data) + size_t(y) * CGImageGetBytesPerRow(image), RasterWidth * 4);
    CFRelease(data);
    return true;
}

bool trimPreservesFrames(Runtime& runtime, SDBMetalRenderer *gpu) {
    if (!gpu.supported) return true;
    const auto solid = [&](float red, float green, float blue) {
        GPUFixture fixture;
        fixture.logicalSize = CGSizeMake(runtime.geometry.logicalSize.width, runtime.geometry.logicalSize.height);
        auto points = quad(runtime);
        for (Vertex& point : points) { point.r=red;point.g=green;point.b=blue;point.a=1; }
        fixture.append(points, {0,0,0,0,0x2100,0,1,0,0,0,0}, false);
        return fixture;
    };
    const GPUFixture red = solid(1,0,0), green = solid(0,1,0), blue = solid(0,0,1);
    std::vector<uint8_t> original, afterTrim, afterQueuedTrim, afterRecovery, retainedPixels;
    if (!captureFixture(gpu, red, original, 1, 1)) return false;
    struct Snapshot {
        CGImageRef image;
        ~Snapshot() { if (image) CGImageRelease(image); }
    } retained{[gpu copyCurrentFrame]};
    id<MTLTexture> texture = gpu.latestTexture;
    [gpu trimTransientResources];
    Snapshot rebuilt{[gpu copyCurrentFrame]};
    if (!require(gpu.latestTexture == texture, "trim retains the currently rendered game texture") ||
        !snapshotBytes(rebuilt.image, afterTrim) ||
        !require(afterTrim == original, "readback rebuild after trim is byte-identical")) return false;

    id<MTLSharedEvent> gate = [gpu.device newSharedEvent];
    if (gate) {
        // Gate the renderer's queue before submitting, making the pending frame
        // deterministic instead of relying on how quickly a GPU finishes it.
        id<MTLCommandQueue> queue = [gpu valueForKey:@"queue"];
        id<MTLCommandBuffer> blocker = [queue commandBuffer];
        [blocker encodeWaitForEvent:gate value:1];
        [blocker commit];
        const bool submitted = [gpu renderVertices:green.vertices.data() vertexCount:green.vertices.size()
            draws:green.draws.data() drawCount:green.draws.size() logicalSize:green.logicalSize
            pixelWidth:RasterWidth pixelHeight:RasterHeight];
        id<MTLCommandBuffer> pending = [gpu valueForKey:@"latestRender"];
        if (!require(submitted && pending.status != MTLCommandBufferStatusCompleted &&
                pending.status != MTLCommandBufferStatusError, "trim fixture has a genuinely queued GPU frame")) {
            gate.signaledValue = 1;
            return false;
        }
        // Core Image may synchronize while clearing its caches. A bounded
        // fallback releases only this fixture's artificial GPU gate if needed.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ gate.signaledValue = 1; });
        [gpu trimTransientResources];
        gate.signaledValue = 1;
        Snapshot queued{[gpu copyCurrentFrame]};
        if (!snapshotBytes(queued.image, afterQueuedTrim)) return false;
        for (size_t p=0; p<afterQueuedTrim.size(); p+=4)
            if (!require(afterQueuedTrim[p] == 0 && afterQueuedTrim[p+1] == 255 &&
                    afterQueuedTrim[p+2] == 0 && afterQueuedTrim[p+3] == 255,
                    "queued GPU vertices and output survive cache trimming")) return false;
    } else return require(false, "available Metal device could not create the shared event required by the queued trim fixture");
    if (!captureFixture(gpu, blue, afterRecovery, 1, 1) ||
        !snapshotBytes(retained.image, retainedPixels) ||
        !require(retainedPixels == original, "caller-retained snapshot remains immutable after trim and later frames")) return false;
    for (size_t p=0; p<afterRecovery.size(); p+=4)
        if (!require(afterRecovery[p] == 0 && afterRecovery[p+1] == 0 &&
                afterRecovery[p+2] == 255 && afterRecovery[p+3] == 255,
                "ordinary rendering and readback recover after trim")) return false;
    printf("PASS cache trim preserves current/queued frames, retained snapshot ownership, and later GPU rendering\n");
    return true;
}

bool prepareMenus(NSString *resources, Texture& gameStart) {
    double maximumAlphaError = 0, maximumColorError = 0;
    for (NSString *name in @[@"game_start.png", @"credits.png", @"continue.png",
                             @"continue_left.png", @"quit.png", @"options.png"]) {
        Texture texture;
        if (!loadTexture(resources, name, texture)) return false;
        auto foreground = texture.pixels;
        std::vector<uint8_t> shadows(texture.pixels.size() / 4);
        for (size_t p = 0; p < texture.pixels.size(); p += 4) {
            const double alpha = texture.pixels[p + 3] / 255.;
            const double ink = std::clamp(texture.pixels[p] / 238. * alpha, 0., alpha);
            const double shadow = ink < 1 ? std::clamp((alpha - ink) / (1 - ink), 0., 1.) : 0;
            foreground[p + 3] = uint8_t(std::round(ink * 255));
            shadows[p / 4] = uint8_t(std::round(shadow * 255));
            const double quantizedInk = foreground[p + 3] / 255.;
            const double quantizedShadow = shadows[p / 4] / 255.;
            // Compare visible premultiplied color and alpha. Straight RGB at
            // near-zero alpha magnifies harmless 8-bit quantization errors.
            maximumAlphaError = std::max(maximumAlphaError,
                std::abs((quantizedInk + quantizedShadow * (1 - quantizedInk)) * 255 - texture.pixels[p + 3]));
            maximumColorError = std::max(maximumColorError,
                std::abs(238 * quantizedInk - texture.pixels[p] * alpha));
        }
        auto field = sdb::text::TextDistanceField::make(foreground, texture.width, texture.height);
        if (!require(field.size() == texture.pixels.size(), "menu foreground SDF exists")) return false;
        for (size_t p = 0; p < texture.pixels.size(); p += 4) {
            texture.pixels[p] = shadows[p / 4]; texture.pixels[p + 1] = texture.pixels[p + 2] = 238;
            texture.pixels[p + 3] = field[p + 3];
        }
        texture.distanceField = 2;
        if ([name isEqualToString:@"game_start.png"]) gameStart = std::move(texture);
    }
    printf("%s six baked labels: texel-center alpha max=%.6f premultiplied RGB max=%.6f bytes\n",
           maximumAlphaError <= MaximumByteError && maximumColorError <= MaximumByteError ? "PASS" : "FAIL",
           maximumAlphaError, maximumColorError);
    return require(maximumAlphaError <= MaximumByteError && maximumColorError <= MaximumByteError,
                   "foreground/shadow decomposition within one byte");
}
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "Usage: RendererTests <Resources/Original directory>\n"); return 2; }
        NSString *resources = [NSString stringWithUTF8String:argv[1]];
        if (!require(resources != nil, "resource path is UTF-8")) return 2;
        Texture menu, font, originalFont;
        if (!prepareMenus(resources, menu) || !loadTexture(resources, @"font_s.png", font) ||
            !loadTexture(resources, @"font.png", originalFont)) return 1;
        if (!require(menu.width == 32 && menu.height == 256 && font.width == 128 && font.height == 128 &&
                     originalFont.width == 256 && originalFont.height == 256,
                     "original fixture asset dimensions")) return 1;
        Texture originalSmallFont = font;
        // Production keeps the supplied glyph alpha and extends its white ink
        // into transparent RGB, preventing a dark fringe under linear sampling.
        for (Texture *atlas : {&originalSmallFont, &originalFont}) {
            atlas->glyphAtlas = true;
            for (size_t p = 0; p < atlas->pixels.size(); p += 4)
                atlas->pixels[p] = atlas->pixels[p + 1] = atlas->pixels[p + 2] = 255;
        }
        font.pixels = sdb::text::TextDistanceField::make(font.pixels, font.width, font.height);
        font.distanceField = 1;
        if (!require(!font.pixels.empty(), "font atlas SDF exists")) return 1;

        Runtime runtime;
        runtime.geometry = DisplayGeometry::make({RasterWidth, RasterHeight}, 1);
        SDBMetalRenderer *gpu = [SDBMetalRenderer new];
        if (!gpu.supported) {
            if (gpu.device) {
                fprintf(stderr, "FAIL Metal initialization on an available device: %s\n",
                        gpu.failure.UTF8String ?: "renderer did not become ready");
                return 1;
            }
            printf("SKIP GPU parity: no Metal device; CPU checks continue.\n");
        }
        if (gpu.supported && !require([[gpu valueForKey:@"pipelines"] count] == 3,
                                     "three common blend pipelines exist before the first frame")) return 1;

        // Distinct RGB and alpha values catch channel swaps or dropped alpha
        // when the software sampler interpolates all four components together.
        Texture rgba;
        rgba.width = rgba.height = 2;
        rgba.pixels = {64,96,128,0, 128,64,96,255, 96,128,64,128, 64,96,128,64};
        auto colorVertices = quad(runtime);
        if (!renderCPU(runtime, rgba, colorVertices) || !pixel(runtime, 5, 5, 0, 0, 255) ||
            !pixel(runtime, 75, 5, 128, 64, 96) || !pixel(runtime, 75, 35, 16, 24, 223) ||
            !compareGPU(runtime, gpu, "independent RGBA bilinear channels", rgba, colorVertices)) return 1;

        Texture edge;
        edge.width = edge.height = 2; edge.distanceField = 1;
        edge.pixels = {255,255,255,0, 255,255,255,255, 255,255,255,0, 255,255,255,255};
        auto vertices = quad(runtime, 0, 0, 1, 1, float(.5 / runtime.geometry.pixelsPerLogicalUnit));
        if (!renderCPU(runtime, edge, vertices) || !pixel(runtime, 39, 10, 0, 0, 255) ||
            !pixel(runtime, 40, 10, 128, 128, 255) || !pixel(runtime, 41, 10, 255, 255, 255) ||
            !compareGPU(runtime, gpu, "straight SDF coverage", edge, vertices)) return 1;
        const auto forwardPixels = runtime.pixels;
        for (size_t i = 0; i < vertices.size(); i += 3) std::swap(vertices[i + 1], vertices[i + 2]);
        if (!renderCPU(runtime, edge, vertices) || !require(runtime.pixels == forwardPixels, "winding-independent CPU coverage") ||
            !compareGPU(runtime, gpu, "reversed winding", edge, vertices)) return 1;

        // A shadow with no foreground must darken blue, rather than disappear.
        Texture shadow;
        shadow.width = shadow.height = 1; shadow.distanceField = 2;
        shadow.pixels = {128, 238, 238, 0};
        vertices = quad(runtime);
        if (!renderCPU(runtime, shadow, vertices) || !pixel(runtime, 20, 10, 0, 0, 127) ||
            !compareGPU(runtime, gpu, "mode2 pure shadow", shadow, vertices)) return 1;

        vertices = quad(runtime, 0, 48.f / font.height, 40.f / font.width, 68.f / font.height);
        if (!renderCPU(runtime, font, vertices) || !compareGPU(runtime, gpu, "original font_s at2x", font, vertices)) return 1;
        // Both supplied atlases contain the same 16-by-8 glyph grid. Reuse one
        // normalized HUD-digit cell on an identical logical glyph quad, keeping
        // the original 1:2 glyph proportions. Its doubled source resolution
        // changes this glyph from 2x to 1x output without changing its metrics.
        vertices = quad(runtime, 0, 3.f / 8, 1.f / 16, 4.f / 8);
        const float logicalWidth = float(runtime.geometry.logicalSize.width);
        const float logicalHeight = float(runtime.geometry.logicalSize.height);
        const float glyphWidth = float(originalFont.width / 16 / runtime.geometry.pixelsPerLogicalUnit);
        const float glyphHeight = float(originalFont.height / 8 / runtime.geometry.pixelsPerLogicalUnit);
        for (Vertex& vertex : vertices) {
            vertex.x = vertex.x / logicalWidth * glyphWidth + (logicalWidth - glyphWidth) / 2;
            vertex.y = vertex.y / logicalHeight * glyphHeight + (logicalHeight - glyphHeight) / 2;
        }
        if (!renderCPU(runtime, originalSmallFont, vertices) ||
            !compareGPU(runtime, gpu, "original font_s alpha at2x shared UV", originalSmallFont, vertices) ||
            !renderCPU(runtime, originalFont, vertices) ||
            !compareGPU(runtime, gpu, "original font alpha at1x shared UV", originalFont, vertices)) return 1;
        // A quarter-pixel placement forces actual bilinear interpolation across
        // original antialiased edges rather than sampling only texel centers.
        const float quarterPixel = float(.25 / runtime.geometry.pixelsPerLogicalUnit);
        for (Vertex& vertex : vertices) vertex.x += quarterPixel;
        if (!renderCPU(runtime, originalFont, vertices) ||
            !compareGPU(runtime, gpu, "original font alpha fractional linear sampling", originalFont, vertices)) return 1;
        if (!glyphAtlasIsolation(runtime, gpu)) return 1;
        // Rotate the original portrait label UVs into landscape; this crop has
        // curved glyph edges and the original soft shadow at two output pixels
        // per source pixel, rather than an artificially generated font sample.
        const float width = float(runtime.geometry.logicalSize.width), height = float(runtime.geometry.logicalSize.height);
        vertices = {{0,0,4.f/32,32.f/256,1,1,1,1}, {width,0,4.f/32,72.f/256,1,1,1,1},
            {0,height,24.f/32,32.f/256,1,1,1,1}, {0,height,24.f/32,32.f/256,1,1,1,1},
            {width,0,4.f/32,72.f/256,1,1,1,1}, {width,height,24.f/32,72.f/256,1,1,1,1}};
        if (!renderCPU(runtime, menu, vertices) || !compareGPU(runtime, gpu, "original GAMESTART mode2 at2x", menu, vertices)) return 1;
        if (!batchParity(runtime, gpu, "RGBA overlap batching", rgba, false) ||
            !batchParity(runtime, gpu, "additive overlap batching", rgba, false, 1) ||
            !batchParity(runtime, gpu, "original glyph cell batching", originalFont, true) ||
            !batchParity(runtime, gpu, "SDF overlap batching", menu, false) ||
            !batchStateBoundaries(runtime, gpu, rgba) || !trimPreservesFrames(runtime, gpu)) return 1;
        printf("PASS CPU coverage, winding, shadow, original font alpha/linear and six-label decomposition; GPU parity %s.\n",
               gpu.supported ? "passed" : "SKIPPED");
        return 0;
    }
}
