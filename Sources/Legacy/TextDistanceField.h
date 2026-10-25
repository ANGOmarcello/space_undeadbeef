//
//  TextDistanceField.h
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//

#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <new>
#include <stdexcept>
#include <vector>

namespace sdb::text {

// Converts existing alpha artwork into an 8-bit signed distance field. This
// does not classify artwork, invent glyphs, change outlines, or add padding.
// Call only for suitable grayscale letter textures; output RGB is white so the
// original rendering color/tint can still be applied by the host shader.
class TextDistanceField {
public:
    static constexpr double DefaultSpread = 4;

    // Source must contain width*height*4 RGBA bytes. The vector overload checks
    // its byte count as well. Output has the same dimensions and RGBA layout.
    // Alpha encodes clamp(0.5 + signedDistance/(2*spread), 0, 1), positive
    // inside the original glyph. Distances/spread are in source-image pixels.
    // Existing partial-alpha pixels contribute their subpixel coverage a-0.5.
    // Fully transparent/opaque masks saturate to 0/255: the image boundary is
    // not silently treated as an invented opposite region outside the canvas.
    // Invalid dimensions, spread, or allocation failure return an empty vector.
    static std::vector<uint8_t> make(const uint8_t* rgba, uint32_t width,
                                     uint32_t height, double spread = DefaultSpread) {
        size_t count = 0;
        if (!rgba || !pixelCount(width, height, count) || !std::isfinite(spread) || spread <= 0) return {};
        try {
            bool empty = true, full = true;
            for (size_t i = 0; i < count; ++i) {
                const uint8_t alpha = rgba[i * 4 + 3];
                empty = empty && alpha == 0;
                full = full && alpha == 255;
            }
            std::vector<uint8_t> result(count * 4, 255);
            if (empty || full) {
                if (empty) for (size_t i = 0; i < count; ++i) result[i * 4 + 3] = 0;
                return result;
            }

            const double infinity = std::numeric_limits<double>::infinity();
            std::vector<double> toInside(count), toOutside(count);
            for (size_t i = 0; i < count; ++i) {
                const uint8_t alpha = rgba[i * 4 + 3];
                if (alpha == 0) { toInside[i] = infinity; toOutside[i] = 0; }
                else if (alpha == 255) { toInside[i] = 0; toOutside[i] = infinity; }
                else {
                    const double coverage = double(alpha) / 255 - .5;
                    toInside[i] = coverage < 0 ? coverage * coverage : 0;
                    toOutside[i] = coverage > 0 ? coverage * coverage : 0;
                }
            }
            Workspace work(std::max(width, height));
            transform(toInside, width, height, work);
            transform(toOutside, width, height, work);
            for (size_t i = 0; i < count; ++i) {
                const double distance = std::sqrt(toOutside[i]) - std::sqrt(toInside[i]);
                result[i * 4 + 3] = encode(distance, spread, rgba[i * 4 + 3]);
            }
            return result;
        } catch (const std::bad_alloc&) {
            return {};
        } catch (const std::length_error&) {
            return {};
        }
    }

    static std::vector<uint8_t> make(const std::vector<uint8_t>& rgba, uint32_t width,
                                     uint32_t height, double spread = DefaultSpread) {
        size_t count = 0;
        if (!pixelCount(width, height, count) || rgba.size() < count * 4) return {};
        return make(rgba.data(), width, height, spread);
    }

private:
    struct Workspace {
        std::vector<double> line, distance, cuts;
        std::vector<size_t> sites;
        explicit Workspace(size_t length)
            : line(length), distance(length), cuts(length + 1), sites(length) {}
    };

    static bool pixelCount(uint32_t width, uint32_t height, size_t& count) {
        if (width == 0 || height == 0) return false;
        const uint64_t wide = uint64_t(width) * height;
        if (wide > std::numeric_limits<size_t>::max() / 4 ||
            wide > std::vector<double>().max_size()) return false;
        count = size_t(wide);
        return true;
    }

    static uint8_t encode(double distance, double spread, uint8_t originalAlpha) {
        // Divide before multiplying by .5 to avoid overflow for large spreads.
        const double value = .5 + (distance / spread) * .5;
        uint8_t encoded;
        if (value <= 0) encoded = 0;
        else if (value >= 1) encoded = 255;
        else if (!std::isfinite(value)) encoded = originalAlpha; // Defensive NaN fallback.
        else encoded = uint8_t(std::round(value * 255));
        // 0.5 lies between bytes127/128. Keep the sign even when an unusually
        // large spread rounds both sides to that same quantized contour.
        return originalAlpha >= 128 ? std::max(uint8_t(128), encoded)
                                    : std::min(uint8_t(127), encoded);
    }

    // Separable squared Euclidean distance transform: lower envelope of
    // parabolas, linear work per row/column. Infinite-cost sites are omitted,
    // which avoids infinity-infinity arithmetic on empty rows or columns.
    // Algorithm reference: Felzenszwalb and Huttenlocher, Distance Transforms
    // of Sampled Functions, https://cs.brown.edu/people/pfelzens/papers/dt-final.pdf
    static void transformLine(size_t length, Workspace& work) {
        const double infinity = std::numeric_limits<double>::infinity();
        size_t siteCount = 0;
        for (size_t q = 0; q < length; ++q) {
            if (!std::isfinite(work.line[q])) continue;
            double crossing = -infinity;
            while (siteCount != 0) {
                const size_t previous = work.sites[siteCount - 1];
                // Equivalent to the difference of squared positions, but avoids
                // subtracting two large squares for neighboring faraway sites.
                crossing = (work.line[q] - work.line[previous]) /
                           (2 * (double(q) - double(previous))) +
                           (double(q) + double(previous)) / 2;
                if (crossing > work.cuts[siteCount - 1]) break;
                --siteCount;
            }
            work.sites[siteCount] = q;
            work.cuts[siteCount] = siteCount == 0 ? -infinity : crossing;
            ++siteCount;
            work.cuts[siteCount] = infinity;
        }
        if (siteCount == 0) {
            std::fill(work.distance.begin(), work.distance.begin() + length, infinity);
            return;
        }
        size_t site = 0;
        for (size_t q = 0; q < length; ++q) {
            while (site + 1 < siteCount && work.cuts[site + 1] < double(q)) ++site;
            const size_t source = work.sites[site];
            const double delta = double(q) - double(source);
            work.distance[q] = delta * delta + work.line[source];
        }
    }

    static void transform(std::vector<double>& grid, uint32_t width, uint32_t height,
                          Workspace& work) {
        for (size_t x = 0; x < width; ++x) {
            for (size_t y = 0; y < height; ++y) work.line[y] = grid[y * width + x];
            transformLine(height, work);
            for (size_t y = 0; y < height; ++y) grid[y * width + x] = work.distance[y];
        }
        for (size_t y = 0; y < height; ++y) {
            const size_t row = y * width;
            for (size_t x = 0; x < width; ++x) work.line[x] = grid[row + x];
            transformLine(width, work);
            for (size_t x = 0; x < width; ++x) grid[row + x] = work.distance[x];
        }
    }
};

} // namespace sdb::text
