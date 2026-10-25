//
//  DisplayGeometryTests.cpp
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//
// Standalone geometry checks; no Apple framework, simulator, or user data.
// clang++ -std=c++17 -Wall -Wextra -Werror Tests/DisplayGeometryTests.cpp \
//     -o /private/tmp/<task-directory>/DisplayGeometryTests

#include "../Sources/Legacy/DisplayGeometry.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

using namespace sdb::display;

namespace {
unsigned checks = 0;
void require(bool success, const std::string& message) {
    ++checks;
    if (!success) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
void near(double actual, double expected, const std::string& message, double tolerance = 1e-9) {
    require(std::isfinite(actual) && std::abs(actual - expected) <= tolerance * std::max(1.0, std::abs(expected)),
            message + " (actual " + std::to_string(actual) + ", expected " + std::to_string(expected) + ")");
}
void nearPoint(Point actual, Point expected, const std::string& message) {
    near(actual.x, expected.x, message + " x"); near(actual.y, expected.y, message + " y");
}
void integer(double value, const std::string& message) { near(value, std::round(value), message); }

void coverage(const DisplayGeometry& g, const std::string& label) {
    require(g.valid, label + " valid geometry");
    require(g.logicalSize.width >= 480 && g.logicalSize.height >= 320, label + " arena never shrinks original domain");
    require(g.logicalSize.width == 480 || g.logicalSize.height == 320, label + " exactly one original axis is retained");
    nearPoint(g.logicalToView({0, 0}), {0, 0}, label + " full world begins at view edge");
    nearPoint(g.logicalToView({g.logicalSize.width, g.logicalSize.height}),
              {g.viewSize.width, g.viewSize.height}, label + " full world reaches view edges without bars");
    const Point origin = g.logicalToView({100, 100});
    const Point across = g.logicalToView({140, 100});
    const Point down = g.logicalToView({100, 140});
    near(across.x - origin.x, down.y - origin.y, label + " artwork has uniform scale on both axes");
    nearPoint(g.originalToView({240, 160}), {g.viewSize.width / 2, g.viewSize.height / 2},
              label + " original artwork remains centered");
    nearPoint(g.guestToView({0, 0}), {g.viewSize.width / 2, g.viewSize.height / 2},
              label + " guest origin remains centered");
    near(g.guestArenaRect.width, g.logicalSize.height, label + " guest arena rotates width");
    near(g.guestArenaRect.height, g.logicalSize.width, label + " guest arena rotates height");
    const Size rasterView = g.rasterViewSize();
    require(rasterView.width >= g.viewSize.width - 1e-9 && rasterView.height >= g.viewSize.height - 1e-9,
            label + " rounded canvas covers full view");
    require((rasterView.width - g.viewSize.width) * g.renderScale < 1.000000001 &&
            (rasterView.height - g.viewSize.height) * g.renderScale < 1.000000001,
            label + " fractional canvas overscan is less than one pixel");
    for (Point p : std::vector<Point>{{0, 0}, {g.viewSize.width, g.viewSize.height},
                                     {g.viewSize.width * .23, g.viewSize.height * .79},
                                     {-17.25, g.viewSize.height + 8.5}}) {
        nearPoint(g.logicalToView(g.viewToLogical(p)), p, label + " view/logical round trip");
        nearPoint(g.originalToView(g.viewToOriginal(p)), p, label + " view/original round trip");
        nearPoint(g.guestToView(g.viewToGuest(p)), p, label + " view/guest round trip");
        const Point logical = g.viewToLogical(p);
        nearPoint(g.pixelToLogical(g.logicalToPixel(logical)), logical, label + " logical/pixel round trip");
    }
}

void originalViewport() {
    const auto g = DisplayGeometry::make({480, 320}, 1);
    coverage(g, "original viewport");
    near(g.logicalSize.width, 480, "original width"); near(g.logicalSize.height, 320, "original height");
    require(g.rasterWidth == 480 && g.rasterHeight == 320, "original pixel canvas");
    nearPoint(g.viewToGuest({0, 0}), {-160, -240}, "original top-left guest coordinates");
    nearPoint(g.viewToGuest({480, 320}), {160, 240}, "original bottom-right guest coordinates");
    nearPoint(g.viewToOriginal({47, 91}), {47, 91}, "original input unchanged at base size");
    near(g.originalUIRegion.width, 480, "original UI full width");
    near(g.originalUIRegion.height, 320, "original UI full height");
}

// Fixture pixels/scales read from Xcode 27.2's installed device profiles under
// /Library/Developer/CoreSimulator/Profiles/DeviceTypes/<name>.simdevicetype/
// Contents/Resources/capabilities.plist, capabilities.ScreenDimensionsCapability.
// Insets below are deliberately asymmetric test inputs, not device constants.
void deviceFixtures() {
    const auto pro = DisplayGeometry::make({2622.0 / 3, 1206.0 / 3}, 3, {0, 62, 21, 34});
    coverage(pro, "iPhone 18 Pro landscape");
    require(pro.rasterWidth == 2622 && pro.rasterHeight == 1206, "Pro native Retina pixels");
    near(pro.logicalSize.height, 320, "Pro retains original logical height");
    near(pro.logicalSize.width, 695.7213930348258, "Pro expands horizontal arena");
    require(pro.originalArtworkRect.x > 0 && pro.originalArtworkRect.y == 0, "Pro has logical side arena extension");
    nearPoint(pro.logicalToView({pro.safeUIRect.x, pro.safeUIRect.y}), {62, 0}, "Pro left safe anchor");
    nearPoint(pro.logicalToView({pro.safeUIRect.maxX(), pro.safeUIRect.maxY()}), {840, 381}, "Pro asymmetric safe anchors");
    require(pro.viewToOriginal({0, 201}).x < 0, "expanded Pro input is not clamped to original screen");

    const auto padLandscape = DisplayGeometry::make({2752.0 / 2, 2064.0 / 2}, 2, {24, 0, 20, 0});
    coverage(padLandscape, "iPad Pro M5 landscape");
    require(padLandscape.rasterWidth == 2752 && padLandscape.rasterHeight == 2064, "iPad landscape native pixels");
    near(padLandscape.logicalSize.width, 480, "iPad landscape original width");
    near(padLandscape.logicalSize.height, 360, "iPad landscape expands vertical arena");
    near(padLandscape.originalArtworkRect.y, 20, "iPad landscape original artwork origin");

    const auto padPortrait = DisplayGeometry::make({2064.0 / 2, 2752.0 / 2}, 2, {24, 0, 20, 0});
    coverage(padPortrait, "iPad Pro M5 portrait");
    require(padPortrait.rasterWidth == 2064 && padPortrait.rasterHeight == 2752, "iPad portrait native pixels");
    near(padPortrait.logicalSize.width, 480, "iPad portrait original width");
    near(padPortrait.logicalSize.height, 640, "iPad portrait full-height arena");
    near(padPortrait.originalArtworkRect.y, 160, "iPad portrait original artwork origin");

    const auto watch = DisplayGeometry::make({416.0 / 2, 496.0 / 2}, 2, {26, 4, 18, 4});
    coverage(watch, "Watch Series 12 portrait");
    require(watch.rasterWidth == 416 && watch.rasterHeight == 496, "Watch native pixels");
    near(watch.logicalSize.width, 480, "Watch retains original logical width");
    near(watch.logicalSize.height, 572.3076923076923, "Watch expands world through full portrait height");
    nearPoint(watch.logicalToView({watch.safeUIRect.x, watch.safeUIRect.y}), {4, 26}, "Watch safe top anchor");
    nearPoint(watch.logicalToView({watch.safeUIRect.maxX(), watch.safeUIRect.maxY()}), {204, 230}, "Watch safe bottom anchor");
    require(watch.safeUIRect.height > watch.originalUIRegion.height, "Watch reflow anchors use more than center landscape band");
    const double legibleFont = watch.logicalLengthForViewPoints(16);
    near(legibleFont * watch.pointsPerLogicalUnit, 16, "font point-size conversion uses consuming view");
    require(watch.fontPixelSize(legibleFont) == 32, "Watch font raster uses native 2x output pixels");
}

void safeInsetsAndRegions() {
    const auto plain = DisplayGeometry::make({800, 600}, 2);
    const auto safe = DisplayGeometry::make({800, 600}, 2, {90, 120, 40, 20});
    near(safe.logicalSize.width, plain.logicalSize.width, "safe insets do not shrink world width");
    near(safe.logicalSize.height, plain.logicalSize.height, "safe insets do not shrink world height");
    require(safe.rasterWidth == plain.rasterWidth && safe.rasterHeight == plain.rasterHeight,
            "safe insets do not produce framebuffer bars");
    nearPoint(safe.logicalToView({0, 0}), {0, 0}, "drawing extends underneath safe insets");
    nearPoint(safe.logicalToView({safe.originalUIRegion.x, safe.originalUIRegion.y}), {120, 90}, "original UI clips to safe top/left");
    nearPoint(safe.logicalToView({safe.originalUIRegion.maxX(), safe.originalUIRegion.maxY()}), {780, 560}, "original UI clips to safe bottom/right");
    const Point clamped = safe.safeUIRect.clamp(safe.viewToLogical({0, 600}));
    nearPoint(safe.logicalToView(clamped), {120, 560}, "explicit safe UI clamp");

    const double nan = std::numeric_limits<double>::quiet_NaN();
    const double infinity = std::numeric_limits<double>::infinity();
    const auto malformed = DisplayGeometry::make({100, 200}, 2, {nan, -12, infinity, infinity});
    require(malformed.valid, "malformed insets do not invalidate valid viewport");
    near(malformed.safeInsets.top, 0, "NaN inset clamps to zero");
    near(malformed.safeInsets.left, 0, "negative inset clamps to zero");
    near(malformed.safeInsets.bottom, 200, "infinite bottom inset clamps to view height");
    near(malformed.safeInsets.right, 100, "infinite right inset clamps to view width");
    require(malformed.safeUIRect.empty() && malformed.originalUIRegion.empty(), "exhausted safe area is explicit empty region");
    const auto overlapping = DisplayGeometry::make({100, 200}, 2, {180, 80, 60, 40});
    near(overlapping.safeInsets.top, 150, "overlapping insets retain top/bottom ratio");
    near(overlapping.safeInsets.bottom, 50, "overlapping bottom inset ratio");
    near(overlapping.safeInsets.left, 200.0 / 3, "overlapping left inset ratio");
    near(overlapping.safeInsets.right, 100.0 / 3, "overlapping right inset ratio");
    require(overlapping.safeUIRect.empty(), "overlapping insets cannot make negative UI size");
}

void budgetsAndPixelAlignment() {
    const auto native = DisplayGeometry::make({208, 248}, 2);
    const auto limited = DisplayGeometry::make({208, 248}, 2, {}, 50000);
    require(limited.valid && limited.budgetLimited, "explicit CPU budget is applied");
    require(limited.pixelCount() <= 50000, "integer raster remains within budget after rounding");
    near(limited.logicalSize.width, native.logicalSize.width, "budget preserves logical width");
    near(limited.logicalSize.height, native.logicalSize.height, "budget preserves logical height");
    nearPoint(limited.viewToGuest({50, 170}), native.viewToGuest({50, 170}), "budget does not change input mapping");
    near(limited.pixelsPerLogicalUnit / limited.pointsPerLogicalUnit, limited.renderScale, "budget has one uniform raster scale");
    const auto onePixel = DisplayGeometry::make({208, 248}, 2, {}, 1);
    require(onePixel.valid && onePixel.pixelCount() == 1, "one-pixel budget is bounded and defined");
    const auto unlimited = DisplayGeometry::make({208, 248}, 2, {}, std::numeric_limits<uint64_t>::max());
    require(unlimited.valid && !unlimited.budgetLimited && unlimited.pixelCount() == 416 * 496,
            "large budget retains native raster");

    for (const auto& g : {native, limited, DisplayGeometry::make({853.25, 611.125}, 2.5)}) {
        for (Point anchor : {Point{10.21, 49.57}, Point{-2.9, .04}, Point{479.88, 319.99}}) {
            const Point snapped = g.snapLogicalPointToPixel(anchor);
            const Point pixels = g.logicalToPixel(snapped);
            integer(pixels.x, "text anchor lands on pixel column"); integer(pixels.y, "text baseline lands on pixel row");
            const Point original = g.logicalToPixel(anchor);
            require(std::abs(pixels.x - original.x) <= .500000001 && std::abs(pixels.y - original.y) <= .500000001,
                    "text anchor movement bounded to half pixel");
        }
        const Rect glyph{18.13, 29.27, 12.4, 21.9};
        const Rect aligned = g.snapLogicalRectOutwardToPixels(glyph);
        require(aligned.contains({glyph.x, glyph.y}) && aligned.contains({glyph.maxX(), glyph.maxY()}),
                "outward glyph alignment covers original glyph");
        for (Point p : {Point{aligned.x, aligned.y}, Point{aligned.maxX(), aligned.maxY()}}) {
            const Point pixel = g.logicalToPixel(p);
            integer(pixel.x, "glyph x edge pixel aligned"); integer(pixel.y, "glyph y edge pixel aligned");
        }
        require(g.fontPixelSize(22) >= 1, "font raster size positive");
        require(g.fontPixelSize(0) == 0 && g.fontPixelSize(-1) == 0, "invalid font sizes rejected");
    }
    const auto fractional = DisplayGeometry::make({853.25, 611.125}, 2.5);
    coverage(fractional, "fractional resized view");
    require(fractional.rasterWidth == 2134 && fractional.rasterHeight == 1528, "fractional point raster rounds outward");
}

void rasterAxisLimits() {
    const auto exact = DisplayGeometry::make({8192, 640}, 1);
    require(exact.valid && !exact.budgetLimited && exact.rasterWidth == 8192,
            "exact default axis limit retains native pixels");
    for (Size size : {Size{8193, 640}, Size{640, 8193}}) {
        const auto native = DisplayGeometry::make(size, 1, {}, 0, 16384);
        const auto limited = DisplayGeometry::make(size, 1);
        coverage(limited, "axis-limited view");
        require(limited.budgetLimited && limited.maximumRasterDimension == 8192,
                "default axis limit is recorded and applied");
        require(limited.rasterWidth <= 8192 && limited.rasterHeight <= 8192,
                "both ceil-rounded raster axes remain within backend limit");
        require(std::max(limited.rasterWidth, limited.rasterHeight) == 8192,
                "oversized axis uses available resolution");
        require(limited.pixelCount() < 16 * 1024 * 1024,
                "axis cap applies independently of total-pixel budget");
        near(limited.displayScale, 1, "axis limit preserves normalized display scale");
        near(limited.renderScale, 8192.0 / 8193, "axis limit permits backing scale below one");
        near(limited.logicalSize.width, native.logicalSize.width, "axis cap preserves logical width");
        near(limited.logicalSize.height, native.logicalSize.height, "axis cap preserves logical height");
        nearPoint(limited.viewToGuest({size.width * .27, size.height * .63}),
                  native.viewToGuest({size.width * .27, size.height * .63}),
                  "axis cap preserves inverse input mapping");
        near(limited.pixelsPerLogicalUnit / limited.pointsPerLogicalUnit, limited.renderScale,
             "axis limit retains uniform pixel scale");

        const auto both = DisplayGeometry::make(size, 3, {}, 1000000);
        coverage(both, "combined axis and pixel limits");
        require(both.budgetLimited && both.pixelCount() <= 1000000 &&
                both.rasterWidth <= 8192 && both.rasterHeight <= 8192,
                "combined resource budgets bound actual integer raster");
        require(both.renderScale < limited.renderScale, "stricter pixel budget further reduces capped scale");
        near(both.displayScale, 3, "combined budgets retain native display density metadata");

        const auto generousPixels = DisplayGeometry::make(size, 3, {}, 8000000);
        require(generousPixels.valid && generousPixels.budgetLimited &&
                generousPixels.pixelCount() <= 8000000 &&
                std::max(generousPixels.rasterWidth, generousPixels.rasterHeight) == 8192,
                "axis limit remains binding with a looser pixel budget");
    }
    const auto custom = DisplayGeometry::make({853.25, 611.125}, 2.5, {}, 0, 1023);
    coverage(custom, "custom fractional axis limit");
    require(custom.budgetLimited && custom.maximumRasterDimension == 1023 &&
            custom.rasterWidth <= 1023 && custom.rasterHeight <= 1023,
            "custom cap constrains ceil-rounded fractional point raster");
    const auto single = DisplayGeometry::make({8193, 640}, 3, {}, 0, 1);
    require(single.valid && single.rasterWidth == 1 && single.rasterHeight == 1 && single.budgetLimited,
            "one-pixel axis limit remains defined");
    const auto zero = DisplayGeometry::make({480, 320}, 1, {}, 0, 0);
    require(!zero.valid && zero.error == GeometryError::unrepresentable &&
            zero.rasterWidth == 0 && zero.rasterHeight == 0,
            "zero raster-axis capacity fails explicitly");
}

void resizingAndValidation() {
    for (unsigned i = 0; i < 80; ++i) {
        const Size size{180.125 + i * 13.75, 251.875 + (i % 11) * 59.5};
        const auto g = DisplayGeometry::make(size, 1 + (i % 9) / 4.0,
                                             {double(i % 17), double(i % 23), double(i % 13), double(i % 7)});
        coverage(g, "dynamic resize " + std::to_string(i));
        nearPoint(g.logicalToView({g.safeUIRect.x, g.safeUIRect.y}),
                  {g.safeInsets.left, g.safeInsets.top}, "resize refreshes safe UI anchors");
    }
    const double infinity = std::numeric_limits<double>::infinity();
    const double nan = std::numeric_limits<double>::quiet_NaN();
    for (Size invalid : {Size{0, 320}, Size{480, 0}, Size{-1, 320}, Size{480, -1},
                         Size{nan, 320}, Size{480, infinity}}) {
        const auto g = DisplayGeometry::make(invalid, 2);
        require(!g.valid && g.error == GeometryError::invalidViewSize, "invalid view dimensions rejected");
        require(g.rasterWidth == 0 && g.rasterHeight == 0, "invalid geometry has no raster");
        nearPoint(g.viewToGuest({0, 0}), {0, 0}, "invalid mapping has safe empty result");
    }
    for (double scale : {0.0, -1.0, nan, infinity}) {
        const auto g = DisplayGeometry::make({480, 320}, scale);
        require(!g.valid && g.error == GeometryError::invalidDisplayScale, "invalid scale rejected");
    }
    near(DisplayGeometry::make({480, 320}, .5).displayScale, 1, "positive low scale normalized to supported range");
    near(DisplayGeometry::make({480, 320}, 8).displayScale, 3, "high scale normalized to supported range");
    const auto underflow = DisplayGeometry::make({std::numeric_limits<double>::denorm_min(), 320}, 1);
    require(!underflow.valid && underflow.error == GeometryError::unrepresentable, "unrepresentable scale fails explicitly");
    const auto hugeBudgeted = DisplayGeometry::make({1e200, 1e200}, 3, {}, 4096);
    require(hugeBudgeted.valid && hugeBudgeted.pixelCount() <= 4096, "huge finite view respects integer budget without cast overflow");
}
}

int main() {
    originalViewport();
    deviceFixtures();
    safeInsetsAndRegions();
    budgetsAndPixelAlignment();
    rasterAxisLimits();
    resizingAndValidation();
    std::cout << "Passed " << checks << " DisplayGeometry checks.\n";
    std::cout << "This proves geometry and mapping, not renderer or device UI integration.\n";
}
