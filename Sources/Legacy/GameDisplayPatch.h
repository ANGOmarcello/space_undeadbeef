//
//  GameDisplayPatch.h
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//

#pragma once

#include "DisplayGeometry.h"
#include "GuestCPU.h"

#include <cstdint>
#include <vector>

namespace sdb::display {

// Geometry adaptations for the single, SHA-256-verified original executable.
// This changes its loaded data only. Simulation clocks, projectile velocities,
// collision shapes, saves, allocations and existing game objects stay intact.
class GameDisplayPatch {
public:
    // Call once after loading Mach-O segments, before running constructors or
    // creating the extended native audio Options table. Captures an immutable
    // baseline, and checks every edited literal, path table and menu table.
    bool initialize(GuestCPU& cpu);
    // The host opts into Watch HUD placement explicitly. A portrait viewport
    // alone must never select this policy (for example, on iPad).
    bool apply(GuestCPU& cpu, const DisplayGeometry& geometry, bool watchLayout = false);

    // Watch HUD layout/verification band uses the full surface bottom, with
    // rounded-edge clearance plus one glyph row and horizontal/top safe bounds.
    // Original HUD content centers as one group within its horizontal bounds.
    // It never changes the playable arena or original player travel bounds.
    static Rect watchHUDRect(const DisplayGeometry& geometry);

    // Keep this inexpensive guard in the CPU hook's C++ fast path, before
    // dispatching Objective-C API bridges. These are aligned instruction PCs;
    // calls to original Thumb functions elsewhere still use address | 1.
    static inline bool handlesPc(uint32_t pc) {
        switch (pc) {
            case 0x5a3c: // Background visible span, separately from scroll speed.
            case 0xc5ba: // Snake head's initial vertical coordinate.
            case 0xc5ce: // Snake head's initial horizontal coordinate.
                return true;
            default:
                return false;
        }
    }
    bool handleInstruction(GuestCPU& cpu, uint32_t pc);

private:
    enum class MenuKind { centered, titleArtwork, version, pause };
    struct Coordinate { uint32_t address; float original; bool horizontal; };
    struct MenuRow {
        uint32_t address;
        float x, y, width, height;
        MenuKind kind;
    };

    bool initialized_ = false;
    double width_ = DisplayGeometry::OriginalWidth;
    double height_ = DisplayGeometry::OriginalHeight;
    std::vector<Coordinate> coordinates_;
    std::vector<MenuRow> menus_;

    static double mapCoordinate(float original, double originalExtent, double extent);
};

} // namespace sdb::display
