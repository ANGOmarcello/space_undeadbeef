//
//  DrawAssemblyTests.mm
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//
// Exercise actual guest-array draw assembly without creating an engine, Metal
// device, audio output, save directory, or user preferences.
#include "../Sources/Legacy/SDBEngine.mm"
#include <cstdio>

namespace {
unsigned checks = 0;

bool require(bool condition, const char *message) {
    ++checks;
    if (!condition) fprintf(stderr, "FAIL %s\n", message);
    return condition;
}

void prepare(Runtime& runtime) {
    runtime.metal = true; // Collect vertices; never submit them to a GPU.
    runtime.vertices = {0x1000, 0x1406, 2, 0};
    runtime.uvs = {0x10000, 0x1406, 2, 0};
    runtime.color[0] = .25f;
    runtime.color[1] = .5f;
    runtime.color[2] = .75f;
    for (unsigned index = 0; index < 4096; ++index) {
        runtime.cpu.write32(0x1000 + index * 8, bits(float(index)));
        runtime.cpu.write32(0x1004 + index * 8, bits(float(index * 2)));
        runtime.cpu.write32(0x10000 + index * 8, bits(.125f));
        runtime.cpu.write32(0x10004 + index * 8, bits(.875f));
    }
}

void clearOutput(Runtime& runtime) {
    runtime.metalVertices.clear();
    runtime.metalDraws.clear();
}

bool vertexMatches(const SDBMetalVertex& vertex, unsigned sourceIndex) {
    return require(vertex.x == 240 + float(sourceIndex * 2) &&
        vertex.y == 160 + float(sourceIndex), "first offset and original axis transform") &&
        require(vertex.u == .125f && vertex.v == .875f, "guest UVs survive assembly") &&
        require(vertex.r == .25f && vertex.g == .5f && vertex.b == .75f && vertex.a == 1,
                "original draw tint survives assembly");
}

bool topologyAndReuse() {
    Runtime runtime;
    prepare(runtime);
    struct Fixture { uint32_t mode; unsigned count; std::vector<unsigned> indices; };
    const Fixture fixtures[] = {
        {4, 6, {0, 1, 2, 3, 4, 5}},
        {5, 4, {0, 1, 2, 1, 2, 3}},
        {6, 4, {0, 1, 2, 0, 2, 3}}
    };
    for (const auto& fixture : fixtures) {
        clearOutput(runtime);
        runtime.draw(fixture.mode, 1, fixture.count);
        if (!require(runtime.cpu.fault.empty(), "valid draw has no fault") ||
            !require(runtime.metalVertices.size() == fixture.indices.size(), "primitive vertex count") ||
            !require(runtime.metalDraws.size() == 1, "one original draw record")) return false;
        for (size_t index = 0; index < fixture.indices.size(); ++index)
            if (!vertexMatches(runtime.metalVertices[index], fixture.indices[index] + 1)) return false;
    }
    for (uint32_t mode : {4u, 5u, 6u}) for (unsigned count : {0u, 1u, 2u}) {
        clearOutput(runtime);
        runtime.draw(mode, 0, count);
        if (!require(runtime.metalVertices.empty() && runtime.metalDraws.empty(),
                     "incomplete primitive emits no stale vertices")) return false;
    }
    clearOutput(runtime);
    runtime.draw(5, 0, 4096);
    if (!require(runtime.metalVertices.size() == 3 * (4096 - 2), "maximum strip remains complete")) return false;
    clearOutput(runtime);
    runtime.draw(4, 7, 3);
    if (!require(runtime.metalVertices.size() == 3, "smaller draw drops stale scratch tail")) return false;
    for (unsigned index = 0; index < 3; ++index)
        if (!vertexMatches(runtime.metalVertices[index], index + 7)) return false;
    const uint64_t draws = runtime.draws;
    runtime.draw(4, 0, 4097);
    if (!require(runtime.cpu.fault == "GL draw count exceeds limit", "oversized draw retains fault") ||
        !require(runtime.draws == draws && runtime.metalVertices.size() == 3,
                 "oversized draw fails before bookkeeping or output changes")) return false;
    runtime.cpu.fault.clear();
    runtime.draw(99, 0, 0);
    return require(runtime.cpu.fault == "Unsupported GL primitive mode", "empty unknown primitive still faults");
}

bool titleAndBackground() {
    Runtime runtime;
    prepare(runtime);
    runtime.textured = true;
    runtime.texture = 3;
    Texture sky;
    sky.width = sky.contentWidth = 960;
    sky.height = sky.contentHeight = 640;
    runtime.textures[ExtendedTitle] = std::move(sky);
    runtime.draw(5, 0, 4);
    if (!require(runtime.metalDraws.size() == 2 && runtime.metalVertices.size() == 12,
                 "title adds one sky strip before original strip") ||
        !require(runtime.metalDraws[0].textureID == ExtendedTitle && runtime.metalDraws[1].textureID == 3 &&
                 runtime.texture == 3, "sky precedes title and restores original texture") ||
        !require(runtime.metalDraws[0].firstVertex == 0 && runtime.metalDraws[1].firstVertex == 6,
                 "title draw ordering stays explicit")) return false;
    const auto& first = runtime.metalVertices.front();
    const auto& last = runtime.metalVertices[5];
    if (!require(first.x == 0 && first.y == 0 && first.u == .25f && first.v == .25f &&
                 last.x == 480 && last.y == 320 && last.u == .75f && last.v == .75f,
                 "sky bounds and original centered UV crop") ||
        !require(first.r == .25f && first.g == .5f && first.b == .75f && first.a == 1,
                 "fixed sky array retains original tint")) return false;
    clearOutput(runtime);
    runtime.draw(5, 0, 4);
    if (!require(runtime.metalDraws.size() == 1 && runtime.metalVertices.size() == 6,
                 "subsequent title draw emits no second sky")) return false;

    clearOutput(runtime);
    runtime.geometry = DisplayGeometry::make({480, 480}, 1);
    runtime.texture = 38;
    runtime.matrix = Matrix::translation(10, 20, 0);
    runtime.stack.push_back(runtime.matrix);
    runtime.draw(4, 1, 3);
    // The camera maps source (1,2) to (262,251). Uniform 1.5x cover about
    // its transformed world corner (20,10) gives (383,371.5).
    if (!require(runtime.metalVertices[0].x == 383 && runtime.metalVertices[0].y == 371.5f,
                 "tall background retains camera-relative uniform scale")) return false;
    runtime.stack.clear();
    runtime.draw(4, 0, 3);
    return require(runtime.cpu.fault == "Background draw lacks its original camera matrix",
                   "missing background camera retains fault");
}

bool colorAndBlendFaults() {
    Runtime runtime;
    runtime.geometry = DisplayGeometry::make({2, 2}, 1);
    runtime.pixels.assign(16, 0);
    runtime.textured = runtime.blend = true;
    runtime.texture = 7;
    Texture texture;
    texture.width = texture.height = 1;
    texture.pixels = {128, 64, 32, 192};
    runtime.textures[7] = std::move(texture);
    const Vertex a = {0, 0, .5f, .5f, .5f, .25f, 1, .5f};
    Vertex b = a, c = a;
    b.x = 480;
    c.y = 480;
    const auto draw = [&] {runtime.triangle(a, b, c);};
    const auto pixel = [&](unsigned red, unsigned green, unsigned blue) {
        return runtime.pixels[0] == red && runtime.pixels[1] == green &&
            runtime.pixels[2] == blue && runtime.pixels[3] == 255;
    };
    draw();
    if (!require(pixel(96, 48, 24), "REPLACE ignores vertex tint and preserves sampled alpha")) return false;
    std::fill(runtime.pixels.begin(), runtime.pixels.end(), 0);
    runtime.textureEnv = 0x2100;
    draw();
    if (!require(pixel(24, 6, 12), "MODULATE retains vertex tint and alpha")) return false;
    std::fill(runtime.pixels.begin(), runtime.pixels.end(), 0);
    runtime.textureEnv = 0x1e01;
    runtime.texture = 999;
    draw();
    if (!require(pixel(63, 31, 127), "missing texture retains original interpolated color")) return false;
    runtime.sourceBlend = 0xdead;
    draw();
    if (!require(runtime.cpu.fault == "Unsupported GL blend factor", "invalid source blend still faults")) return false;
    runtime.cpu.fault.clear();
    runtime.sourceBlend = 0x302;
    runtime.destBlend = 0xdead;
    draw();
    return require(runtime.cpu.fault == "Unsupported GL blend factor", "invalid destination blend still faults");
}
}

int main() {
    @autoreleasepool {
        if (!topologyAndReuse() || !titleAndBackground() || !colorAndBlendFaults()) return 1;
        printf("Passed %u draw assembly checks.\n", checks);
    }
}
