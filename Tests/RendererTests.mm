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
                const Texture& texture, const std::vector<Vertex>& vertices) {
    if (!gpu.supported) return true;
    if (![gpu setTexture:FixtureTexture rgba:texture.pixels.data() byteLength:texture.pixels.size()
                  width:texture.width height:texture.height]) {
        fprintf(stderr, "FAIL upload %s: %s\n", name, gpu.failure.UTF8String); return false;
    }
    auto background = quad(runtime);
    std::vector<SDBMetalVertex> metal;
    for (const Vertex& v : background) metal.push_back({v.x, v.y, 0, 0, 0, 0, 1, 1});
    for (const Vertex& v : vertices) metal.push_back({v.x, v.y, v.u, v.v, v.r, v.g, v.b, v.a});
    const SDBMetalDraw draws[] = {
        {0, uint32_t(background.size()), 0, 0, 0x2100, 0, 1, 0, 0, 0},
        {uint32_t(background.size()), uint32_t(vertices.size()), FixtureTexture, 1, 0x1e01,
            1, 0x302, 0x303, 0, texture.distanceField}
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
        Texture menu, font;
        if (!prepareMenus(resources, menu) || !loadTexture(resources, @"font_s.png", font)) return 1;
        if (!require(menu.width == 32 && menu.height == 256 && font.width == 128 && font.height == 128,
                     "original fixture asset dimensions")) return 1;
        font.pixels = sdb::text::TextDistanceField::make(font.pixels, font.width, font.height);
        font.distanceField = 1;
        if (!require(!font.pixels.empty(), "font atlas SDF exists")) return 1;

        Runtime runtime;
        runtime.geometry = DisplayGeometry::make({RasterWidth, RasterHeight}, 1);
        SDBMetalRenderer *gpu = [SDBMetalRenderer new];
        if (!gpu.supported) printf("SKIP GPU parity: %s; CPU checks continue.\n", gpu.failure.UTF8String ?: "Metal unavailable");

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
        // Rotate the original portrait label UVs into landscape; this crop has
        // curved glyph edges and the original soft shadow at two output pixels
        // per source pixel, rather than an artificially generated font sample.
        const float width = float(runtime.geometry.logicalSize.width), height = float(runtime.geometry.logicalSize.height);
        vertices = {{0,0,4.f/32,32.f/256,1,1,1,1}, {width,0,4.f/32,72.f/256,1,1,1,1},
            {0,height,24.f/32,32.f/256,1,1,1,1}, {0,height,24.f/32,32.f/256,1,1,1,1},
            {width,0,4.f/32,72.f/256,1,1,1,1}, {width,height,24.f/32,72.f/256,1,1,1,1}};
        if (!renderCPU(runtime, menu, vertices) || !compareGPU(runtime, gpu, "original GAMESTART mode2 at2x", menu, vertices)) return 1;
        printf("PASS CPU coverage, winding, shadow and six-label decomposition; GPU parity %s.\n",
               gpu.supported ? "passed" : "SKIPPED");
        return 0;
    }
}
