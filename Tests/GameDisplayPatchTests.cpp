//
//  GameDisplayPatchTests.cpp
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//
// Standalone checks against the original Mach-O, without running its startup,
// opening a UI, playing audio, or touching app saves and user preferences.
// Build with GuestCPU.cpp and GameDisplayPatch.cpp; pass Resources/Original/psh.

#include "../Sources/Legacy/GameDisplayPatch.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <set>
#include <string>
#include <vector>

using sdb::display::DisplayGeometry;
using sdb::display::GameDisplayPatch;

namespace {
unsigned checks = 0;
void require(bool result, const std::string& message) {
    ++checks;
    if (!result) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
uint32_t bits(float value) { uint32_t word; std::memcpy(&word, &value, 4); return word; }
float real(uint32_t word) { float value; std::memcpy(&value, &word, 4); return value; }
uint32_t word(const std::vector<uint8_t>& bytes, size_t offset) {
    if (offset > bytes.size() || bytes.size() - offset < 4) require(false, "fixture word is bounded");
    return uint32_t(bytes[offset]) | (uint32_t(bytes[offset + 1]) << 8) |
           (uint32_t(bytes[offset + 2]) << 16) | (uint32_t(bytes[offset + 3]) << 24);
}
void near(GuestCPU& cpu, uint32_t address, double wanted, const std::string& message) {
    const double actual = real(cpu.read32(address));
    require(std::isfinite(actual) && std::abs(actual - wanted) <= 0.0001,
            message + " (actual " + std::to_string(actual) + ", wanted " + std::to_string(wanted) + ")");
}
void healthy(const GuestCPU& cpu, const std::string& message) {
    require(cpu.fault.empty(), message + ": " + cpu.fault);
}

void loadMachO(GuestCPU& cpu, const std::vector<uint8_t>& bytes) {
    require(word(bytes, 0) == 0xfeedface && word(bytes, 4) == 12, "fixture is 32-bit ARM Mach-O");
    const uint32_t commands = word(bytes, 16);
    require(commands < 100, "fixture command count is bounded");
    size_t offset = 28;
    for (uint32_t index = 0; index < commands; ++index) {
        const uint32_t command = word(bytes, offset), size = word(bytes, offset + 4);
        require(size >= 8 && size <= bytes.size() - offset, "fixture command size is bounded");
        if (command == 1) {
            require(size >= 56, "fixture segment command has fixed fields");
            const uint32_t address = word(bytes, offset + 24), file = word(bytes, offset + 32);
            const uint32_t length = word(bytes, offset + 36);
            require(file <= bytes.size() && length <= bytes.size() - file, "fixture segment is in file");
            if (length) require(cpu.load(address, bytes.data() + file, length), "fixture segment loads");
        }
        offset += size;
    }
    healthy(cpu, "Mach-O loaded without running guest code");
}

std::vector<uint8_t> prefix(const GuestCPU& cpu) {
    return {cpu.memory.begin(), cpu.memory.begin() + 0x20000};
}

void protectedData(GuestCPU& cpu, const std::vector<uint8_t>& baseline) {
    for (uint32_t address : {0x5aa8u, 0x5adcu, 0x5460u, 0x4ae8u, 0xb9f0u,
                             0xb9f4u, 0xb9f8u, 0xd134u, 0xd304u, 0xc668u})
        require(cpu.read32(address) == word(baseline, address), "physical speed/angle literal remains original");

    for (uint32_t record = 0x11c88; record < 0x12a68; record += 24) {
        require(cpu.read32(record) == word(baseline, record), "enemy path type is unchanged");
        for (uint32_t field : {12u, 16u, 20u})
            require(cpu.read32(record + field) == word(baseline, record + field),
                    "enemy durations, firing modes and firing periods are unchanged");
        if (word(baseline, record) == 3 || word(baseline, record) == 0) {
            require(std::equal(baseline.begin() + record, baseline.begin() + record + 24,
                               cpu.memory.begin() + record), "homing records and sentinels are byte-identical");
        }
    }

    // Catch unintended edits elsewhere in executable instructions, scenario
    // data, vtables, collision/size constants and game globals.
    std::set<uint32_t> allowed = {
        0x5ce8,0x7234,0x9180,0xb5d8,0xe63c,0x2d20,0x5cf0,0x723c,0x9188,0xb5dc,0xe644,
        0x2910,0x2e80,0x28f4,0x5ab4,0x5ab8,0x82f8,0x830c,0x8340,0x82fc,0x8304,0x833c,
        0xdba0,0xdba4,0x94ec,0x94f0,0x94f4,0x94f8,0xa274,0xa3ec,0xa3f0,0xd798,0xd79c,
        0xd13c,0xd314
    };
    for (uint32_t record = 0x11c88; record < 0x12a68; record += 24)
        if (word(baseline, record) == 1 || word(baseline, record) == 2) {
            allowed.insert(record + 4); allowed.insert(record + 8);
        }
    for (uint32_t address = 0x12b30; address < 0x12b50; address += 4) allowed.insert(address);
    for (uint32_t record = 0x14688; record < 0x14f70; record += 60)
        if (word(baseline, record + 8) && word(baseline, record + 12))
            for (uint32_t field = 0; field < 16; field += 4) allowed.insert(record + field);
    bool intact = true;
    for (uint32_t address = 0; address < baseline.size(); address += 4) {
        if (!allowed.count(address) && cpu.read32(address) != word(baseline, address)) { intact = false; break; }
    }
    require(intact, "all other loaded bytes retain the original simulation and executable");
}

void hookTests(GuestCPU& cpu, GameDisplayPatch& patch) {
    cpu.hook = [&patch](GuestCPU& guest, uint32_t pc) {
        return GameDisplayPatch::handlesPc(pc) && patch.handleInstruction(guest, pc);
    };
    cpu.thumb = true; cpu.n = true; cpu.z = false; cpu.c = false; cpu.v = true;
    cpu.r[0] = 0xdeadbeef; cpu.r[1] = 0; cpu.r[15] = 0x5a3c;
    require(cpu.step(), "background span hook executes through CPU dispatch");
    require(cpu.r[1] == bits(960) && cpu.r[0] == 0xdeadbeef && cpu.r[15] == 0x5a3e,
            "background hook changes only the LDR destination and advances one halfword");
    require(cpu.n && !cpu.z && !cpu.c && cpu.v && cpu.thumb, "background hook preserves flags and Thumb");
    near(cpu, 0x5aa8, 480, "shared background scroll normalization is unmodified");

    cpu.r[15] = 0xc5ba;
    require(cpu.step(), "boss initial vertical LDR hook executes");
    require(cpu.r[2] == bits(-300) && cpu.r[15] == 0xc5bc, "boss vertical coordinate keeps its offscreen margin");
    // Execute the actual following store with the original instruction, then
    // the separately hooked Y store that formerly shared the same literal.
    cpu.r[0] = 0x30014; cpu.r[3] = 0x88; cpu.r[15] = 0xc5c6;
    require(cpu.step(), "original boss vertical store executes");
    near(cpu, 0x3009c, -300, "boss initial vertical state is correct");
    cpu.r[3] = 0x300a0; cpu.r[15] = 0xc5ce;
    require(cpu.step(), "boss horizontal STR hook executes");
    near(cpu, 0x300a8, -540, "boss initial horizontal state moves beyond the expanded left edge");
    require(cpu.r[2] == bits(-300) && cpu.r[3] == 0x300a0 && cpu.r[15] == 0xc5d0,
            "store hook preserves both source and base registers");
    require(cpu.n && !cpu.z && !cpu.c && cpu.v && cpu.thumb, "boss hooks preserve all flags");
    require(!GameDisplayPatch::handlesPc(0x5a3d) && !GameDisplayPatch::handlesPc(0x5a38) &&
            !patch.handleInstruction(cpu, 0x5a38), "only the three aligned PCs are intercepted");
    healthy(cpu, "hook sequence");

    cpu.r[3] = 0xfffffff8; cpu.r[15] = 0xc5ce;
    const uint32_t zero = cpu.read32(0);
    require(!cpu.step() && !cpu.fault.empty(), "boss store rejects wrapping guest addresses");
    require(cpu.read32(0) == zero, "wrapping boss store does not overwrite guest address zero");
    cpu.fault.clear();

    cpu.write16(0x5a3c, 0x4900); cpu.r[15] = 0x5a3c; cpu.r[1] = 123;
    require(!cpu.step(), "changed geometry instruction fails closed");
    require(!cpu.fault.empty() && cpu.r[1] == 123, "changed instruction does not write a substitute value");
    cpu.fault.clear(); cpu.write16(0x5a3c, 0x491a);
}

void resizeTests(const std::vector<uint8_t>& executable) {
    GuestCPU cpu; loadMachO(cpu, executable);
    const auto baseline = prefix(cpu);
    GameDisplayPatch patch;
    require(patch.initialize(cpu), "original geometry validates: " + cpu.fault);
    require(prefix(cpu) == baseline, "capturing original geometry is read-only");
    const auto original = DisplayGeometry::make({480, 320}, 1);
    require(patch.apply(cpu, original), "original display applies");
    require(prefix(cpu) == baseline, "original viewport is byte-identical to the loaded game");

    const auto wide = DisplayGeometry::make({960, 320}, 2, {8, 48, 16, 16});
    require(patch.apply(cpu, wide), "wide display applies: " + cpu.fault);
    near(cpu, 0x5cf0, 480, "player bullets survive to the actual right edge");
    near(cpu, 0x723c, 480, "enemy bullets traverse the full arena");
    near(cpu, 0xb5dc, 480, "homing enemies terminate beyond the expanded arena");
    near(cpu, 0x2910, -372, "player holds the original sixty-unit inset inside the left safe edge");
    near(cpu, 0x2e80, -372, "player constructor and live anchor both clear the camera cutout");
    near(cpu, 0x2910, wide.safeUIRect.minX() - wide.logicalSize.width / 2 + 60,
         "player anchor follows the consuming view's actual left safe area");
    near(cpu, 0x28f4, -576, "player enters from beyond the expanded left edge");
    near(cpu, 0x11c88 + 8, 520, "enemy spawn keeps its forty-unit offscreen margin");
    near(cpu, 0x11ca0 + 8, 320, "enemy internal route expands across the arena");
    near(cpu, 0x12b30 + 4, 360, "boss target participates in expanded gameplay");
    near(cpu, 0x82f8, -144, "score respects the safe top inset");
    near(cpu, 0x82fc, -402, "score respects the safe left inset");
    near(cpu, 0x833c, 404, "charge indicator respects the safe right inset");
    near(cpu, 0x14ef8, -140, "pause button respects safe top");
    near(cpu, 0x14ef8 + 4, 452, "pause button respects safe right");
    near(cpu, 0x14d54, 0, "original title artwork stays centered");
    near(cpu, 0x14d54 + 8, 320, "title core height is never stretched");
    near(cpu, 0x14d54 + 12, 480, "title core width is never stretched");
    near(cpu, 0xa3f0, 960, "fade spans the full output arena");
    near(cpu, 0x94f8, -960, "camera mask covers the full expanded span");
    near(cpu, 0x148e0 + 52, 32, "original menu font size remains logical and uniform");
    protectedData(cpu, baseline);
    hookTests(cpu, patch);

    const auto iPad = DisplayGeometry::make({1024, 768}, 2);
    require(patch.apply(cpu, iPad), "iPad display applies");
    near(cpu, 0x2d20, 180, "player can move through added iPad height");
    near(cpu, 0x11ef8 + 4, 220, "vertical enemy spawn keeps original forty-unit margin");
    near(cpu, 0x11c88 + 4, 90, "vertical internal route expands with arena height");
    near(cpu, 0xa3ec, 360, "iPad fade covers added height");

    const auto watch = DisplayGeometry::make({216, 242}, 2, {20, 8, 12, 8});
    require(patch.apply(cpu, watch), "Watch display applies");
    near(cpu, 0x2d20, watch.logicalSize.height / 2, "Watch has an actual taller movement arena");
    near(cpu, 0x5ab4, watch.logicalSize.height / 2, "Watch background origin follows expanded height");
    near(cpu, 0x82f8, watch.safeUIRect.minY() - watch.logicalSize.height / 2 + 8,
         "Watch score respects its consuming view's safe inset");
    protectedData(cpu, baseline);
    require(patch.apply(cpu, wide) && patch.apply(cpu, watch) && patch.apply(cpu, original),
            "repeated resizes use immutable baseline data");
    require(prefix(cpu) == baseline, "wide/Watch/original round trip restores every original loaded byte");
    const auto fractional = DisplayGeometry::make({2811.0 / 7, 1000.0 / 3}, 2);
    require(patch.apply(cpu, fractional), "fractional view scale tolerates roundoff at the safe logical edge");
    require(patch.apply(cpu, original) && prefix(cpu) == baseline, "fractional resize also restores the baseline");

    // Emulate the engine's existing native extension, including a version
    // string pointer update that resizing must never replace.
    constexpr uint32_t table = 0x40000;
    std::copy(cpu.memory.begin() + 0x148e0, cpu.memory.begin() + 0x148e0 + 7 * 60, cpu.memory.begin() + table);
    std::copy(cpu.memory.begin() + 0x148e0 + 7 * 60, cpu.memory.begin() + 0x148e0 + 9 * 60,
              cpu.memory.begin() + table + 10 * 60);
    for (uint32_t index = 0; index < 3; ++index) {
        std::copy(cpu.memory.begin() + 0x148e0 + (4 + index) * 60,
                  cpu.memory.begin() + 0x148e0 + (5 + index) * 60, cpu.memory.begin() + table + (7 + index) * 60);
        cpu.write32(table + (7 + index) * 60, bits(real(cpu.read32(0x148e0 + (4 + index) * 60)) + 80));
    }
    cpu.write32(0x14680, table); cpu.write32(0x14d90 + 36, 0x50000);
    const uint32_t callback = cpu.read32(table + 8 * 60 + 40);
    require(patch.apply(cpu, wide), "extended native audio menu reflows");
    const float expectedSilentHeading = -4 + 40 * (296.f / 320);
    near(cpu, table + 7 * 60, expectedSilentHeading, "silent-mode heading follows the same original row layout");
    near(cpu, table + 8 * 60 + 4, -44, "silent ON column centers in safe UI");
    require(cpu.read32(table + 8 * 60 + 40) == callback, "native menu callbacks are preserved");
    require(cpu.read32(0x14d90 + 36) == 0x50000, "native app-version string pointer is preserved");
    require(patch.apply(cpu, original), "extended native menu returns to original display");
    near(cpu, table + 7 * 60, 40, "new audio section also restores original logical row position");

    // Unsupported geometry and tables fail before writing partial patches.
    auto invalid = original; invalid.logicalSize.width = std::numeric_limits<double>::quiet_NaN();
    auto before = prefix(cpu);
    require(!patch.apply(cpu, invalid) && !cpu.fault.empty(), "nonfinite geometry is rejected");
    require(prefix(cpu) == before, "invalid geometry leaves loaded memory untouched");
    cpu.fault.clear(); cpu.write32(0x14680, 0x14688); before = prefix(cpu);
    require(!patch.apply(cpu, wide) && !cpu.fault.empty(), "unsupported custom menu pointer is rejected");
    require(prefix(cpu) == before, "unsupported menu leaves bounds and paths untouched");
}

void rejectionTests(const std::vector<uint8_t>& executable) {
    for (uint32_t address : {0x5cf0u, 0x11c90u, 0x14688u, 0x12b34u, 0x5a3cu}) {
        GuestCPU cpu; loadMachO(cpu, executable);
        cpu.write8(address, uint8_t(cpu.read8(address) ^ 1));
        const auto changed = prefix(cpu);
        GameDisplayPatch patch;
        require(!patch.initialize(cpu) && !cpu.fault.empty(), "changed original geometry fails baseline validation");
        require(prefix(cpu) == changed, "failed initialization does not mutate original memory");
    }
    GuestCPU cpu;
    GameDisplayPatch patch;
    require(!patch.apply(cpu, DisplayGeometry::make({480, 320}, 1)), "apply requires original baseline");
    cpu.fault.clear(); cpu.thumb = true; cpu.r[15] = 0x5a3c;
    require(patch.handleInstruction(cpu, 0x5a3c) && !cpu.fault.empty(), "hook also requires original baseline");
}
} // namespace

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "Resources/Original/psh";
    std::ifstream input(path, std::ios::binary);
    require(input.good(), std::string("original fixture opens: ") + path);
    const std::vector<uint8_t> executable{std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
    resizeTests(executable);
    rejectionTests(executable);
    std::cout << "PASS: " << checks << " display patch checks against original ARM Mach-O\n";
}
