//
//  GameDisplayPatch.cpp
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//

#include "GameDisplayPatch.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <sstream>
#include <utility>

namespace sdb::display {
namespace {

uint32_t bits(float value) { uint32_t word; std::memcpy(&word, &value, sizeof(word)); return word; }
float real(uint32_t word) { float value; std::memcpy(&value, &word, sizeof(value)); return value; }

bool fail(GuestCPU& cpu, const std::string& detail) {
    cpu.fail("Display patch: " + detail);
    return false;
}

bool expected(GuestCPU& cpu, uint32_t address, uint32_t word) {
    if (cpu.read32(address) == word && cpu.fault.empty()) return true;
    std::ostringstream message;
    message << "unexpected original data at 0x" << std::hex << address;
    return fail(cpu, message.str());
}

// The engine separately validates SHA-256 of the whole Mach-O. These bounded
// fingerprints also guard tables before interpreting their record layouts.
bool fingerprint(GuestCPU& cpu, uint32_t first, uint32_t end, uint64_t wanted) {
    uint64_t hash = UINT64_C(14695981039346656037);
    for (uint32_t address = first; address < end; ++address) {
        hash = (hash ^ cpu.read8(address)) * UINT64_C(1099511628211);
    }
    if (hash == wanted && cpu.fault.empty()) return true;
    std::ostringstream message;
    message << "unexpected original table at 0x" << std::hex << first;
    return fail(cpu, message.str());
}

enum class Value {
    halfHeight, halfWidth, playerLeft, playerEntrance, scoreTop, stageTop,
    chargeTop, scoreLeft, highScoreLeft, chargeRight, gaugeTop, gaugeRight,
    negativeHeight, height, width, negativeWidth, messageLeft, bossRetreat
};
struct Literal { uint32_t address; float original; Value value; };
constexpr Literal Literals[] = {
    {0x5ce8, 160, Value::halfHeight}, // Bullet bounds.
    {0x7234, 160, Value::halfHeight}, // EnemyBullet bounds.
    {0x9180, 160, Value::halfHeight}, // Bluster bounds.
    {0xb5d8, 160, Value::halfHeight}, // EnemyScript homing termination.
    {0xe63c, 160, Value::halfHeight}, // EnemyBeam bounds.
    {0x2d20, 160, Value::halfHeight}, // Player movement clamp.
    {0x5cf0, 240, Value::halfWidth},
    {0x723c, 240, Value::halfWidth},
    {0x9188, 240, Value::halfWidth},
    {0xb5dc, 240, Value::halfWidth},
    {0xe644, 240, Value::halfWidth},
    {0x2910, -180, Value::playerLeft},
    {0x2e80, -180, Value::playerLeft},
    {0x28f4, -336, Value::playerEntrance},
    {0x5ab4, 160, Value::halfHeight}, // Background draw origin only.
    {0x5ab8, 240, Value::halfWidth},
    {0x82f8, -152, Value::scoreTop},
    {0x830c, -136, Value::stageTop},
    {0x8340, -145, Value::chargeTop},
    {0x82fc, -210, Value::scoreLeft},
    {0x8304, -64, Value::highScoreLeft},
    {0x833c, 180, Value::chargeRight},
    {0xdba0, -130, Value::gaugeTop},
    {0xdba4, 85, Value::gaugeRight},
    {0x94ec, -320, Value::negativeHeight}, // Masks during camera rotation.
    {0x94f0, 320, Value::height},
    {0x94f4, 480, Value::width},
    {0x94f8, -480, Value::negativeWidth},
    {0xa274, 160, Value::halfHeight}, // Menu buttons enter at the arena edge.
    {0xa3ec, 320, Value::height}, // Full-screen fade.
    {0xa3f0, 480, Value::width},
    {0xd798, -240, Value::messageLeft}, // Original message entrance animation.
    {0xd79c, 240, Value::halfWidth},
    {0xd13c, -120, Value::bossRetreat},
    {0xd314, -120, Value::bossRetreat}
};

constexpr uint32_t TraceBoundaries[] = {
    0x11c88, 0x11dc0, 0x11ef8, 0x11fb8, 0x12078, 0x12138, 0x12288,
    0x12318, 0x123a8, 0x12438, 0x124c8, 0x12558, 0x125e8, 0x12678,
    0x12708, 0x12798, 0x12828, 0x128d0, 0x12978, 0x129f0, 0x12a68
};
struct MenuTable { uint32_t first, count; };
constexpr MenuTable MenuTables[] = {
    {0x14688, 9}, {0x148e0, 8}, {0x14afc, 3}, {0x14bec, 2},
    {0x14ca0, 2}, {0x14d54, 6}, {0x14ef8, 1}
};
constexpr uint32_t OptionsPointer = 0x14680;
constexpr uint32_t OriginalOptions = 0x148e0;
constexpr uint32_t MenuRecordSize = 60;

} // namespace

double GameDisplayPatch::mapCoordinate(float original, double originalExtent, double extent) {
    const double half = originalExtent / 2;
    const double distance = std::abs(double(original));
    // Keep an offscreen spawn's original margin while spreading positions
    // inside the arena. Durations and the original spring integrator remain.
    return distance <= half ? double(original) * (extent / originalExtent)
                            : std::copysign(extent / 2 + distance - half, original);
}

bool GameDisplayPatch::initialize(GuestCPU& cpu) {
    if (!cpu.fault.empty()) return false;
    if (initialized_) return fail(cpu, "baseline was already captured");
    for (const Literal& literal : Literals) {
        if (!expected(cpu, literal.address, bits(literal.original))) return false;
    }
    if (cpu.read16(0x5a3c) != 0x491a || cpu.read16(0xc5ba) != 0x4a2b ||
        cpu.read16(0xc5ce) != 0x609a) return fail(cpu, "unexpected original geometry instructions");
    if (!fingerprint(cpu, 0x11c88, 0x12a68, UINT64_C(0xbf4efe41dcbd1ecd)) ||
        !fingerprint(cpu, 0x14688, 0x14f70, UINT64_C(0xcb577d8952bd2e31)) ||
        !fingerprint(cpu, 0x12b30, 0x12b50, UINT64_C(0x05e8a615e730dac5)) ||
        !expected(cpu, OptionsPointer, OriginalOptions)) return false;

    std::vector<Coordinate> coordinates;
    for (size_t table = 1; table < std::size(TraceBoundaries); ++table) {
        const uint32_t end = TraceBoundaries[table];
        for (uint32_t record = TraceBoundaries[table - 1]; record < end; record += 24) {
            const uint32_t type = cpu.read32(record);
            if (record + 24 == end) {
                if (type != 0) return fail(cpu, "enemy path lacks its original terminator");
            } else {
                if (type < 1 || type > 3) return fail(cpu, "unexpected enemy path type");
                // Type 3 homes to the live player; its remaining fields are
                // deliberately not interpreted as waypoint coordinates.
                if (type != 3) {
                    coordinates.push_back({record + 4, real(cpu.read32(record + 4)), false});
                    coordinates.push_back({record + 8, real(cpu.read32(record + 8)), true});
                }
            }
        }
    }
    for (uint32_t record = 0x12b30; record < 0x12b50; record += 8) {
        coordinates.push_back({record, real(cpu.read32(record)), false});
        coordinates.push_back({record + 4, real(cpu.read32(record + 4)), true});
    }
    std::vector<MenuRow> menus;
    for (const MenuTable& table : MenuTables) {
        for (uint32_t index = 0; index < table.count; ++index) {
            const uint32_t record = table.first + index * MenuRecordSize;
            MenuKind kind = MenuKind::centered;
            if (record == 0x14d54) kind = MenuKind::titleArtwork;
            else if (record == 0x14d90) kind = MenuKind::version;
            else if (record == 0x14ef8) kind = MenuKind::pause;
            menus.push_back({record, real(cpu.read32(record)), real(cpu.read32(record + 4)),
                             real(cpu.read32(record + 8)), real(cpu.read32(record + 12)), kind});
        }
    }
    if (!cpu.fault.empty()) return false;
    coordinates_ = std::move(coordinates);
    menus_ = std::move(menus);
    initialized_ = true;
    return true;
}

bool GameDisplayPatch::apply(GuestCPU& cpu, const DisplayGeometry& geometry) {
    if (!cpu.fault.empty()) return false;
    if (!initialized_) return fail(cpu, "original baseline has not been captured");
    const double width = geometry.logicalSize.width, height = geometry.logicalSize.height;
    const Rect requestedSafe = geometry.safeUIRect;
    const double tolerance = std::max(width, height) * 1e-12;
    if (!geometry.valid || !std::isfinite(width) || !std::isfinite(height) ||
        width < 480 || height < 320 || width > std::numeric_limits<float>::max() / 4 ||
        height > std::numeric_limits<float>::max() / 4 || !requestedSafe.finite() ||
        requestedSafe.minX() < -tolerance || requestedSafe.minY() < -tolerance ||
        requestedSafe.maxX() > width + tolerance || requestedSafe.maxY() > height + tolerance)
        return fail(cpu, "invalid display geometry");
    // Division by a fractional view scale can put an otherwise exact safe
    // edge a fraction of a floating-point ULP beyond the logical rectangle.
    const Rect safe = requestedSafe.intersection({0, 0, width, height});

    // Prepare all writes before mutating memory, so an unsupported extended
    // Options table cannot leave the loaded game partially resized.
    struct Write { uint32_t address, value; };
    std::vector<Write> writes;
    const auto put = [&](uint32_t address, double value) {
        writes.push_back({address, bits(float(value))});
    };
    const double top = safe.minY() - height / 2, left = safe.minX() - width / 2;
    const double right = safe.maxX() - width / 2;
    for (const Literal& literal : Literals) {
        double value = literal.original;
        switch (literal.value) {
            case Value::halfHeight: value = height / 2; break;
            case Value::halfWidth: value = width / 2; break;
            case Value::playerLeft: value = left + 60; break;
            case Value::playerEntrance: value = -width / 2 - 96; break;
            case Value::scoreTop: value = top + 8; break;
            case Value::stageTop: value = top + 24; break;
            case Value::chargeTop: value = top + 15; break;
            case Value::scoreLeft: value = left + 30; break;
            case Value::highScoreLeft: value = left + 176; break;
            case Value::chargeRight: value = right - 60; break;
            case Value::gaugeTop: value = top + 30; break;
            case Value::gaugeRight: value = right - 155; break;
            case Value::negativeHeight: value = -height; break;
            case Value::height: value = height; break;
            case Value::width: value = width; break;
            case Value::negativeWidth: value = -width; break;
            case Value::messageLeft: value = -width / 2; break;
            case Value::bossRetreat: value = mapCoordinate(literal.original, 480, width); break;
        }
        put(literal.address, value);
    }
    for (const Coordinate& coordinate : coordinates_) {
        put(coordinate.address, mapCoordinate(coordinate.original, coordinate.horizontal ? 480 : 320,
                                             coordinate.horizontal ? width : height));
    }
    const Point center = safe.center();
    const double menuX = center.y - height / 2, menuY = center.x - width / 2;
    const double rowScale = std::min(1.0, safe.height / 320);
    const double columnScale = std::min(1.0, safe.width / 480);
    const auto menu = [&](const MenuRow& row, uint32_t destination) {
        double x = menuX + row.x * rowScale, y = menuY + row.y * columnScale;
        double w = row.width, h = row.height;
        // The renderer supplies outpaint behind this unchanged original quad;
        // resizing the core artwork here would stretch its composition.
        if (row.kind == MenuKind::titleArtwork) { x = 0; y = 0; }
        else if (row.kind == MenuKind::pause) { x = top + 12; y = right - 12; }
        else if (row.kind == MenuKind::version) { x = safe.maxY() - height / 2 - 44; }
        put(destination, x); put(destination + 4, y);
        put(destination + 8, w); put(destination + 12, h);
    };
    for (const MenuRow& row : menus_) menu(row, row.address);

    const uint32_t options = cpu.read32(OptionsPointer);
    if (options != OriginalOptions) {
        constexpr uint32_t AudioRows = 12, HapticsRows = 15;
        if (options < 0x20000 || options > cpu.memory.size() - AudioRows * MenuRecordSize)
            return fail(cpu, "extended Options table is outside guest heap");
        const uint32_t audioTerminator = options + (AudioRows - 1) * MenuRecordSize;
        const bool audioOnly = cpu.read32(audioTerminator + 8) == 0 && cpu.read32(audioTerminator + 12) == 0;
        const uint32_t rows = audioOnly ? AudioRows : HapticsRows;
        if (options > cpu.memory.size() - rows * MenuRecordSize)
            return fail(cpu, "extended Options table is outside guest heap");
        for (uint32_t index = 0; index < rows - 1; ++index) {
            if (cpu.read32(options + index * MenuRecordSize + 32) != 62)
                return fail(cpu, "unsupported extended Options row");
        }
        if (cpu.read32(options + (rows - 1) * MenuRecordSize + 8) != 0 ||
            cpu.read32(options + (rows - 1) * MenuRecordSize + 12) != 0)
            return fail(cpu, "extended Options table lacks its terminator");

        const MenuRow *originalRows[8]{};
        for (const MenuRow& original : menus_) {
            if (original.address < OriginalOptions || original.address >= OriginalOptions + 8 * MenuRecordSize) continue;
            const uint32_t index = (original.address - OriginalOptions) / MenuRecordSize;
            originalRows[index] = &original;
        }
        for (const MenuRow *original : originalRows)
            if (!original) return fail(cpu, "original Options geometry is missing");

        if (audioOnly) {
            const double sectionStep = originalRows[4]->x - originalRows[0]->x;
            for (uint32_t index = 0; index < 8; ++index) {
                menu(*originalRows[index], options + (index == 7 ? 10 : index) * MenuRecordSize);
                if (index >= 4 && index <= 6) {
                    MenuRow silent = *originalRows[index];
                    silent.x += float(sectionStep);
                    menu(silent, options + (index + 3) * MenuRecordSize);
                }
            }
        } else {
            // Four sections share the original heading-to-SAVE-EXIT span.
            // Retain each heading's original thirty-unit choice offset and
            // ON/OFF columns while leaving SAVE-EXIT at its original anchor.
            const double firstHeading = originalRows[0]->x;
            const double sectionStep = (originalRows[7]->x - firstHeading) / 4;
            for (uint32_t index = 0; index < HapticsRows - 1; ++index) {
                const uint32_t source = index < 4 ? index : (index == 13 ? 7 : 4 + (index - 4) % 3);
                MenuRow row = *originalRows[source];
                if (index >= 4 && index < 13) {
                    const uint32_t section = 1 + (index - 4) / 3;
                    row.x = float(firstHeading + section * sectionStep + row.x - originalRows[4]->x);
                }
                menu(row, options + index * MenuRecordSize);
            }
        }
    }
    if (!cpu.fault.empty()) return false;
    for (const Write& write : writes) cpu.write32(write.address, write.value);
    if (!cpu.fault.empty()) return false;
    width_ = width; height_ = height;
    return true;
}

bool GameDisplayPatch::handleInstruction(GuestCPU& cpu, uint32_t pc) {
    if (!handlesPc(pc)) return false;
    if (!cpu.fault.empty()) return true;
    if (!initialized_ || !cpu.thumb) {
        fail(cpu, "geometry hook requires initialized Thumb code");
        return true;
    }
    const uint16_t instruction = pc == 0x5a3c ? 0x491a : (pc == 0xc5ba ? 0x4a2b : 0x609a);
    if (cpu.read16(pc) != instruction) {
        fail(cpu, "geometry instruction changed after validation");
        return true;
    }
    if (pc == 0x5a3c) cpu.r[1] = bits(float(width_));
    else if (pc == 0xc5ba) cpu.r[2] = bits(float(mapCoordinate(-300, 320, height_)));
    else {
        const uint64_t address = uint64_t(cpu.r[3]) + 8;
        if (address + 4 > cpu.memory.size()) {
            fail(cpu, "boss geometry store is outside guest memory");
            return true;
        }
        cpu.write32(uint32_t(address), bits(float(mapCoordinate(-300, 480, width_))));
    }
    // LDR literal and STR immediate do not affect NZCV or the instruction set.
    cpu.r[15] = pc + 2;
    return true;
}

} // namespace sdb::display
