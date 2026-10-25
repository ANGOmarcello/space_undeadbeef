//
//  TextDistanceFieldTests.cpp
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//
// Portable standalone checks; no framework, font replacement, or user data.
// clang++ -std=c++17 -Wall -Wextra -Werror Tests/TextDistanceFieldTests.cpp \
//     -o /private/tmp/<task-directory>/TextDistanceFieldTests

#include "../Sources/Legacy/TextDistanceField.h"

#include <cstdlib>
#include <iostream>
#include <string>

using sdb::text::TextDistanceField;

namespace {
unsigned checks = 0;
void require(bool value, const std::string& message) {
    ++checks;
    if (!value) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
std::vector<uint8_t> image(uint32_t width, uint32_t height, uint8_t alpha = 0) {
    std::vector<uint8_t> result(size_t(width) * height * 4);
    for (size_t p = 0; p < result.size(); p += 4) {
        result[p] = 23; result[p + 1] = 91; result[p + 2] = 177; result[p + 3] = alpha;
    }
    return result;
}
uint8_t alpha(const std::vector<uint8_t>& pixels, uint32_t width, uint32_t x, uint32_t y) {
    return pixels[(size_t(y) * width + x) * 4 + 3];
}
void setAlpha(std::vector<uint8_t>& pixels, uint32_t width, uint32_t x, uint32_t y, uint8_t value) {
    pixels[(size_t(y) * width + x) * 4 + 3] = value;
}
void shape(const std::vector<uint8_t>& input, const std::vector<uint8_t>& output, const std::string& label) {
    require(output.size() == input.size(), label + " canvas dimensions retained");
    for (size_t p = 0; p < input.size(); p += 4) {
        require((input[p + 3] >= 128) == (output[p + 3] >= 128), label + " original half-alpha contour classification retained");
        require(output[p] == 255 && output[p + 1] == 255 && output[p + 2] == 255, label + " field RGB is white for original tint");
    }
}

void validationAndConstants() {
    const auto rgba = image(3, 2);
    require(TextDistanceField::make(nullptr, 3, 2).empty(), "null input rejected");
    require(TextDistanceField::make(rgba, 0, 2).empty(), "zero width rejected");
    require(TextDistanceField::make(rgba, 3, 0).empty(), "zero height rejected");
    require(TextDistanceField::make(rgba, 4, 2).empty(), "short source buffer rejected");
    require(TextDistanceField::make(rgba, 3, 2, 0).empty(), "zero spread rejected");
    require(TextDistanceField::make(rgba, 3, 2, -1).empty(), "negative spread rejected");
    require(TextDistanceField::make(rgba, 3, 2, std::numeric_limits<double>::infinity()).empty(), "infinite spread rejected");
    require(TextDistanceField::make(rgba, 3, 2, std::numeric_limits<double>::quiet_NaN()).empty(), "NaN spread rejected");
    require(TextDistanceField::make(rgba.data(), 0xffffffffu, 0xffffffffu).empty(), "pixel/byte count overflow rejected before reading source");
    for (uint8_t value : {uint8_t(0), uint8_t(255)}) {
        const auto original = image(5, 3, value);
        const auto result = TextDistanceField::make(original, 5, 3);
        shape(original, result, value ? "full mask" : "empty mask");
        for (size_t p = 3; p < result.size(); p += 4) require(result[p] == value, "constant masks saturate without invented exterior samples");
    }
    const auto singleOpaque = TextDistanceField::make(image(1, 1, 255), 1, 1);
    require(singleOpaque.size() == 4 && singleOpaque[3] == 255, "one-pixel full canvas remains inside");
    const auto singleEmpty = TextDistanceField::make(image(1, 1, 0), 1, 1);
    require(singleEmpty.size() == 4 && singleEmpty[3] == 0, "one-pixel empty canvas remains outside");
}

void binaryStepAndDistance() {
    auto horizontal = image(8, 1);
    for (uint32_t x = 4; x < 8; ++x) setAlpha(horizontal, 8, x, 0, 255);
    const auto original = horizontal;
    const auto result = TextDistanceField::make(horizontal, 8, 1, 4);
    const uint8_t expected[]{0, 32, 64, 96, 159, 191, 223, 255};
    shape(horizontal, result, "binary horizontal step");
    require(horizontal == original, "input artwork bytes unchanged");
    for (uint32_t x = 0; x < 8; ++x) {
        require(alpha(result, 8, x, 0) == expected[x], "integer step has expected signed distance bytes");
        if (x) require(alpha(result, 8, x, 0) >= alpha(result, 8, x - 1, 0), "step distance is monotonic");
    }
    require(unsigned(expected[3]) + expected[4] == 255, "binary edge crosses 0.5 halfway between original texel centers");
    auto vertical = image(1, 8);
    for (uint32_t y = 4; y < 8; ++y) setAlpha(vertical, 1, 0, y, 255);
    const auto rotated = TextDistanceField::make(vertical, 1, 8);
    for (uint32_t y = 0; y < 8; ++y) require(alpha(rotated, 1, 0, y) == expected[y], "vertical distance matches rotated horizontal distance");

    auto point = image(7, 7);
    setAlpha(point, 7, 3, 3, 255);
    const auto field = TextDistanceField::make(point, 7, 7);
    shape(point, field, "single interior pixel");
    require(alpha(field, 7, 3, 3) == 159, "single ink pixel remains inside");
    require(alpha(field, 7, 4, 3) == 96, "unit Euclidean distance outside");
    require(alpha(field, 7, 4, 4) == 82, "diagonal distance sqrt2 rather than Manhattan2");
    require(alpha(field, 7, 5, 4) == 56, "off-axis Euclidean distance sqrt5");
    require(alpha(field, 7, 0, 0) == 0, "distance beyond spread saturates");
    require(alpha(field, 7, 2, 1) == alpha(field, 7, 4, 5), "distance is symmetric under reflection");
}

void subpixelCoverage() {
    const uint8_t source[]{1, 64, 127, 128, 192, 254};
    const uint8_t expected[]{112, 120, 127, 128, 136, 143};
    for (size_t index = 0; index < sizeof(source); ++index) {
        const auto original = image(1, 1, source[index]);
        const auto result = TextDistanceField::make(original, 1, 1, 4);
        shape(original, result, "subpixel edge");
        require(result[3] == expected[index], "partial alpha retains coverage-minus-half source offset");
    }
    auto ramp = image(8, 1);
    const uint8_t values[]{0, 1, 64, 127, 128, 192, 254, 255};
    for (uint32_t x = 0; x < 8; ++x) setAlpha(ramp, 8, x, 0, values[x]);
    const auto field = TextDistanceField::make(ramp, 8, 1);
    shape(ramp, field, "antialiased ramp");
    for (uint32_t x = 2; x <= 6; ++x)
        require(alpha(field, 8, x, 0) >= alpha(field, 8, x - 1, 0), "subpixel distance is monotonic through edge");
    for (double spread : {1e-300, 1e300}) {
        const auto tinyOutside = TextDistanceField::make(image(1, 1, 127), 1, 1, spread);
        const auto tinyInside = TextDistanceField::make(image(1, 1, 128), 1, 1, spread);
        require(!tinyOutside.empty() && tinyOutside[3] < 128, "outside sign survives finite extreme spread");
        require(!tinyInside.empty() && tinyInside[3] >= 128, "inside sign survives finite extreme spread");
    }
}

void countersAndPadding() {
    auto ring = image(11, 11);
    for (uint32_t y = 2; y <= 8; ++y) for (uint32_t x = 2; x <= 8; ++x) {
        const bool hole = x >= 4 && x <= 6 && y >= 4 && y <= 6;
        setAlpha(ring, 11, x, y, hole ? 0 : 255);
    }
    // Original antialiasing on opposite sides of the counter remains distinct.
    setAlpha(ring, 11, 4, 5, 64);
    setAlpha(ring, 11, 3, 5, 192);
    const auto field = TextDistanceField::make(ring, 11, 11);
    shape(ring, field, "glyph counter and original padding");
    require(alpha(field, 11, 5, 5) < 128, "counter center stays a hole");
    require(alpha(field, 11, 3, 5) >= 128 && alpha(field, 11, 4, 5) < 128, "antialiased counter outline keeps original threshold");
    require(alpha(field, 11, 2, 5) >= 128, "outer stroke not eroded");
    for (uint32_t edge = 0; edge < 11; ++edge) {
        require(alpha(field, 11, edge, 0) < 128 && alpha(field, 11, edge, 10) < 128 &&
                alpha(field, 11, 0, edge) < 128 && alpha(field, 11, 10, edge) < 128,
                "peripheral padding never becomes visible ink at contour");
    }
    require(field.size() == 11 * 11 * 4, "no additional peripheral canvas invented");
}

// Slow mathematical reference, independent of the production parabola-envelope
// algorithm. Each output checks every source pixel's squared Euclidean cost.
uint8_t reference(const std::vector<uint8_t>& rgba, uint32_t width, uint32_t height,
                  uint32_t x, uint32_t y, double spread) {
    double inside = std::numeric_limits<double>::infinity();
    double outside = inside;
    for (uint32_t sy = 0; sy < height; ++sy) for (uint32_t sx = 0; sx < width; ++sx) {
        const uint8_t a = alpha(rgba, width, sx, sy);
        const double dx = double(x) - sx, dy = double(y) - sy;
        const double spatial = dx * dx + dy * dy;
        const double coverage = double(a) / 255 - .5;
        if (a != 0) inside = std::min(inside, spatial + std::pow(std::max(0.0, -coverage), 2));
        if (a != 255) outside = std::min(outside, spatial + std::pow(std::max(0.0, coverage), 2));
    }
    const double signedDistance = std::sqrt(outside) - std::sqrt(inside);
    const double value = std::clamp(.5 + signedDistance / (2 * spread), 0.0, 1.0);
    return uint8_t(std::round(value * 255));
}

void referenceComparison() {
    uint32_t state = 0x12345678;
    const uint8_t levels[]{0, 64, 127, 128, 192, 255};
    for (uint32_t test = 0; test < 80; ++test) {
        const uint32_t width = 1 + test % 13, height = 1 + (test * 7) % 11;
        auto rgba = image(width, height);
        for (size_t p = 3; p < rgba.size(); p += 4) {
            state = state * 1664525u + 1013904223u;
            rgba[p] = levels[(state >> 16) % 6];
        }
        const double spread = test % 3 == 0 ? .75 : test % 3 == 1 ? 2 : 4;
        const auto field = TextDistanceField::make(rgba, width, height, spread);
        shape(rgba, field, "reference image");
        for (uint32_t y = 0; y < height; ++y) for (uint32_t x = 0; x < width; ++x) {
            const int expected = reference(rgba, width, height, x, y, spread);
            const int actual = alpha(field, width, x, y);
            require(std::abs(actual - expected) <= 1, "EDT matches brute-force Euclidean distance within one quantization byte");
        }
    }
}
}

int main() {
    validationAndConstants();
    binaryStepAndDistance();
    subpixelCoverage();
    countersAndPadding();
    referenceComparison();
    std::cout << "Passed " << checks << " TextDistanceField checks.\n";
    std::cout << "Original alpha contours are preserved at texel centers; shader and device rendering need separate verification.\n";
}
