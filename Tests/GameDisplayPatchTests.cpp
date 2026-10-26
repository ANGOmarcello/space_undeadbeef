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

void watchHUDTests(const std::vector<uint8_t>& executable) {
    GuestCPU cpu; loadMachO(cpu, executable);
    const auto baseline = prefix(cpu);
    GameDisplayPatch patch;
    require(patch.initialize(cpu), "Watch HUD captures the original geometry");
    const auto watch = DisplayGeometry::make({208, 248}, 2, {28, 0, 0, 0});
    require(patch.apply(cpu, watch), "Watch-shaped display retains default HUD without explicit policy");
    const auto defaultLayout = prefix(cpu);
    near(cpu, 0x82f8, watch.safeUIRect.minY() - watch.logicalSize.height / 2 + 8,
         "portrait geometry alone keeps the original top HUD");
    require(patch.apply(cpu, watch, true), "explicit Watch policy moves the original HUD");
    const auto band = GameDisplayPatch::watchHUDRect(watch);
    require(std::abs(band.y - 510.3076923076923) < 0.0001 && band.height == 32 && band.width == 480,
            "46mm Watch reserves the measured two-row bottom band");
    require(band.y >= watch.safeUIRect.minY() && band.maxY() <= watch.safeUIRect.maxY() - 30,
            "HUD clears the bottom rounded edge by the original thirty-unit inset");
    const auto withinBand = [&](sdb::display::Point p) {
        // Guest anchors are IEEE float; the host geometry remains double.
        constexpr double tolerance = 0.0001;
        return p.x >= band.minX() - tolerance && p.x <= band.maxX() + tolerance &&
               p.y >= band.minY() - tolerance && p.y <= band.maxY() + tolerance;
    };
    const auto point = [&](uint32_t vertical, uint32_t horizontal) {
        return watch.guestToLogical({real(cpu.read32(vertical)), real(cpu.read32(horizontal))});
    };
    const auto score = point(0x82f8, 0x82fc);
    const auto highScore = point(0x82f8, 0x8304);
    const auto stage = point(0x830c, 0x82fc);
    require(std::abs(score.y - band.y) < 0.0001 && std::abs(stage.y - score.y - 16) < 0.0001,
            "Watch preserves the original sixteen-unit row separation");
    for (const auto& text : {std::make_pair(score, 14u), std::make_pair(highScore, 17u),
                             std::make_pair(stage, 17u)}) {
        require(withinBand(text.first) &&
                withinBand({text.first.x + text.second * 8, text.first.y + 16}),
                "original score, high-score and stage/deaths glyph bounds stay in the bottom band");
    }
    const auto charge = point(0x8340, 0x833c);
    for (unsigned cell = 0; cell < 16; ++cell) {
        for (unsigned vertex = 0; vertex < 4; ++vertex) {
            const double x = charge.x - cell * 6 + real(cpu.read32(0x11b50 + vertex * 8 + 4));
            const double y = charge.y + real(cpu.read32(0x11b50 + vertex * 8));
            require(withinBand({x, y}), "all sixteen original charge quads fit the bottom band");
        }
    }
    const auto gauge = point(0xdba0, 0xdba4);
    for (double amount : {0.0, 100.0}) {
        require(withinBand({gauge.x + 2.67, gauge.y - 4}) &&
                withinBand({gauge.x + amount + 2.67, gauge.y + 4}),
                "empty and full original boss bars fit without overlapping another HUD row");
    }
    require(score.x + 14 * 8 <= highScore.x && highScore.x + 17 * 8 <= charge.x - 15 * 6 - 4,
            "score, high-score and charge columns retain their original nonoverlapping widths");
    const std::set<uint32_t> moved = {0x82f8, 0x830c, 0x8340, 0xdba0};
    bool onlyHUD = true;
    for (uint32_t address = 0; address < defaultLayout.size(); address += 4)
        if (!moved.count(address) && cpu.read32(address) != word(defaultLayout, address)) onlyHUD = false;
    require(onlyHUD, "Watch policy changes only the four HUD vertical anchors, preserving the entire game arena");
    near(cpu, 0x81e8, 8, "Watch keeps original HUD glyph width");
    near(cpu, 0x81f0, 16, "Watch keeps original HUD glyph height");
    const auto insetWatch = DisplayGeometry::make({208, 248}, 2, {28, 8, 12, 8});
    require(patch.apply(cpu, insetWatch, true), "Watch HUD fits real horizontal and bottom safe insets");
    const double insetLeft = insetWatch.safeUIRect.minX();
    const double insetRight = insetWatch.safeUIRect.maxX();
    const double insetHigh = real(cpu.read32(0x8304)) + insetWatch.logicalSize.width / 2;
    const double firstGap = insetHigh - (insetLeft + 30 + 112);
    const double secondGap = insetRight - 154 - (insetHigh + 136);
    require(firstGap >= 0 && secondGap >= 0 && std::abs(firstGap / secondGap - 34.0 / 14) < 0.0001,
            "narrow Watch safe width compresses only the two gaps in their original proportion");
    require(std::abs(insetHigh - 168.3076923076923) < 0.0001,
            "inset Watch high-score column fits between the measured score and charge bounds");
    near(cpu, 0x82fc, insetLeft - insetWatch.logicalSize.width / 2 + 30,
         "Watch score retains the original left inset when gaps compress");
    near(cpu, 0x833c, insetRight - insetWatch.logicalSize.width / 2 - 60,
         "Watch charge retains the original right inset when gaps compress");
    const auto minimumWatch = DisplayGeometry::make({480, 320}, 1, {0, 24, 0, 24});
    require(patch.apply(cpu, minimumWatch, true), "minimum safe Watch HUD width retains every original glyph");
    const double minimumHigh = real(cpu.read32(0x8304)) + 240;
    require(minimumHigh == 24 + 30 + 112 && minimumHigh + 136 == 480 - 24 - 154,
            "minimum safe width removes exactly the empty gaps without overlapping content");
    const auto tooNarrow = DisplayGeometry::make({480, 320}, 1, {0, 25, 0, 25});
    const auto beforeReject = prefix(cpu);
    require(!patch.apply(cpu, tooNarrow, true) && cpu.fault.find("Watch safe region") != std::string::npos,
            "undersized Watch HUD fails with a clear diagnostic before overlapping content");
    require(prefix(cpu) == beforeReject && GameDisplayPatch::watchHUDRect(tooNarrow).empty(),
            "undersized Watch layout rejects atomically");
    cpu.fault.clear();
    const auto tooShort = DisplayGeometry::make({480, 320}, 1, {259, 0, 0, 0});
    require(!patch.apply(cpu, tooShort, true) && cpu.fault.find("Watch safe region") != std::string::npos,
            "Watch safe height cannot clip either HUD row or its rounded-edge clearance");
    require(prefix(cpu) == beforeReject && GameDisplayPatch::watchHUDRect(tooShort).empty(),
            "undersized Watch safe height also rejects atomically");
    cpu.fault.clear();
    require(patch.apply(cpu, watch, true), "full Watch HUD restores after safe-inset changes");
    require(patch.apply(cpu, watch, false) && prefix(cpu) == defaultLayout,
            "turning Watch policy off restores its exact prior top layout");
    const auto portraitPad = DisplayGeometry::make({1032, 1376}, 2);
    require(patch.apply(cpu, portraitPad), "portrait iPad retains its default device policy");
    near(cpu, 0x82f8, -portraitPad.logicalSize.height / 2 + 8,
         "portrait iPad HUD remains at the top");
    require(patch.apply(cpu, watch, true) && patch.apply(cpu, DisplayGeometry::make({480, 320}, 1)),
            "Watch policy can resize and return to the original display");
    require(prefix(cpu) == baseline, "Watch/default/original round trip restores every original loaded byte");
    healthy(cpu, "Watch HUD geometry remains bounded");
}

void hapticsMenuTests(const std::vector<uint8_t>& executable) {
    GuestCPU cpu; loadMachO(cpu, executable);
    const auto baseline = prefix(cpu);
    GameDisplayPatch patch;
    require(patch.initialize(cpu), "haptics menu fixture validates the original executable");
    constexpr uint32_t originalTable = 0x148e0, pointer = 0x14680, table = 0x40000, stride = 60;
    const auto copyRow = [&](uint32_t originalIndex, uint32_t destination) {
        std::copy(cpu.memory.begin() + originalTable + originalIndex * stride,
                  cpu.memory.begin() + originalTable + (originalIndex + 1) * stride,
                  cpu.memory.begin() + destination);
    };
    for (uint32_t index = 0; index < 7; ++index) copyRow(index, table + index * stride);
    for (uint32_t section : {7u, 10u})
        for (uint32_t index = 0; index < 3; ++index) copyRow(4 + index, table + (section + index) * stride);
    copyRow(7, table + 13 * stride); copyRow(8, table + 14 * stride);
    // Unique native callbacks and labels must survive every reflow. No callback
    // executes in this fixture and no host preferences or haptics are accessed.
    for (uint32_t index = 0; index < 14; ++index) {
        cpu.write32(table + index * stride + 36, 0x50000 + index * 16);
        cpu.write32(table + index * stride + 40, 0x01d00001 + index * 4);
        cpu.write32(table + index * stride + 44, 0x01d00081 + index * 4);
    }
    const std::vector<uint8_t> sourceRows(cpu.memory.begin() + table, cpu.memory.begin() + table + 15 * stride);
    cpu.write32(pointer, table); cpu.write32(0x14d90 + 36, 0x60000);
    const auto original = DisplayGeometry::make({480, 320}, 1);
    const auto wide = DisplayGeometry::make({960, 320}, 2, {8, 48, 16, 16});
    const auto watch = DisplayGeometry::make({216, 242}, 2, {20, 8, 12, 8});
    require(patch.apply(cpu, original), "fifteen-row native haptics menu applies");
    constexpr float positions[] = {40, 70, 70, 70, 100, 130, 130, 160, 190, 190, 220, 250, 250, 280};
    for (uint32_t index = 0; index < std::size(positions); ++index) {
        near(cpu, table + index * stride, positions[index] - 160,
             "four compact sections retain their intended logical row positions");
        require(cpu.read32(table + index * stride + 8) == word(sourceRows, index * stride + 8) &&
                cpu.read32(table + index * stride + 12) == word(sourceRows, index * stride + 12),
                "haptics layout retains the original cloned hit-box sizes");
    }
    const std::vector<uint8_t> compact(cpu.memory.begin() + table, cpu.memory.begin() + table + 15 * stride);
    require(patch.apply(cpu, wide), "haptics menu reflows inside a wide view's safe area");
    near(cpu, table + 7 * stride, -4, "silent-mode heading keeps the safe vertical center");
    near(cpu, table + 10 * stride, 51.5, "haptics heading shares the compact safe-area spacing");
    near(cpu, table + 11 * stride, 79.25, "haptics choices retain the scaled thirty-unit heading offset");
    near(cpu, table + 11 * stride + 4, -44, "haptics ON reuses the original safe-area column");
    near(cpu, table + 13 * stride, 107, "SAVE-EXIT retains its original safe-area anchor");
    require(patch.apply(cpu, watch), "fifteen-row geometry also supports a taller viewport");
    near(cpu, table + 10 * stride,
         watch.safeUIRect.center().y - watch.logicalSize.height / 2 + 60,
         "taller viewport centers the compact haptics section in safe UI");
    for (uint32_t index = 0; index < 15; ++index)
        require(std::equal(sourceRows.begin() + index * stride + 16, sourceRows.begin() + (index + 1) * stride,
                           cpu.memory.begin() + table + index * stride + 16),
                "native haptics labels, callbacks and nongeometry fields are untouched");
    require(cpu.read32(0x14d90 + 36) == 0x60000, "haptics reflow preserves the native version string");
    require(patch.apply(cpu, wide) && patch.apply(cpu, original), "haptics geometry resizes from immutable templates");
    require(std::equal(compact.begin(), compact.end(), cpu.memory.begin() + table),
            "wide/tall/original round trip exactly restores all compact native rows");

    cpu.write32(table + 12 * stride + 32, 61);
    auto before = prefix(cpu);
    std::vector<uint8_t> beforeRows(cpu.memory.begin() + table, cpu.memory.begin() + table + 15 * stride);
    require(!patch.apply(cpu, wide) && !cpu.fault.empty(), "unsupported haptics row fails validation");
    require(prefix(cpu) == before && std::equal(beforeRows.begin(), beforeRows.end(), cpu.memory.begin() + table),
            "unsupported haptics row leaves both loaded and native geometry untouched");
    cpu.fault.clear(); cpu.write32(table + 12 * stride + 32, 62);
    cpu.write32(table + 14 * stride + 8, bits(32));
    before = prefix(cpu);
    beforeRows.assign(cpu.memory.begin() + table, cpu.memory.begin() + table + 15 * stride);
    require(!patch.apply(cpu, wide) && !cpu.fault.empty(), "haptics table requires its fifteenth-row terminator");
    require(prefix(cpu) == before && std::equal(beforeRows.begin(), beforeRows.end(), cpu.memory.begin() + table),
            "bad haptics terminator cannot partially resize the game");
    cpu.fault.clear(); cpu.write32(table + 14 * stride + 8, 0);

    // Row eleven is a real choice in the extended table. Check the full length
    // before reading row fourteen, even when the first twelve rows fit exactly.
    const uint32_t truncated = uint32_t(cpu.memory.size()) - 12 * stride;
    std::copy(cpu.memory.begin() + table, cpu.memory.begin() + table + 12 * stride, cpu.memory.begin() + truncated);
    cpu.write32(pointer, truncated); before = prefix(cpu);
    require(!patch.apply(cpu, wide) && cpu.fault.find("outside guest heap") != std::string::npos,
            "fifteen-row detection rejects a truncated table before an out-of-bounds read");
    require(prefix(cpu) == before, "truncated haptics table leaves original game geometry untouched");
    cpu.fault.clear();
    const uint32_t lastValid = uint32_t(cpu.memory.size()) - 15 * stride;
    std::copy(cpu.memory.begin() + table, cpu.memory.begin() + table + 15 * stride, cpu.memory.begin() + lastValid);
    cpu.write32(pointer, lastValid);
    require(patch.apply(cpu, wide), "bounded haptics table may end exactly at guest-memory limit");
    near(cpu, lastValid + 13 * stride, 107, "last valid haptics table still places SAVE-EXIT correctly");
    cpu.write32(pointer, originalTable); cpu.write32(0x14d90 + 36, word(baseline, 0x14d90 + 36));
    require(patch.apply(cpu, original) && prefix(cpu) == baseline,
            "removing native menu extension restores every original loaded byte");
    healthy(cpu, "haptics menu fixture remains bounded");
}

void rejectionTests(const std::vector<uint8_t>& executable) {
    for (uint32_t address : {0x5cf0u, 0x11c90u, 0x14688u, 0x12b34u, 0x5a3cu,
                             0x81e8u, 0x81f0u, 0x8338u, 0x11b54u, 0x11b6cu}) {
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
    watchHUDTests(executable);
    hapticsMenuTests(executable);
    rejectionTests(executable);
    std::cout << "PASS: " << checks << " display patch checks against original ARM Mach-O\n";
}
