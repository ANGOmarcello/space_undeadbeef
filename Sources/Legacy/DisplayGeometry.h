//
//  DisplayGeometry.h
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//

#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

namespace sdb::display {

struct Point { double x = 0, y = 0; };
struct Size { double width = 0, height = 0; };

// Matches the order of UIEdgeInsets, without depending on an Apple framework.
struct Insets { double top = 0, left = 0, bottom = 0, right = 0; };

struct Rect {
    double x = 0, y = 0, width = 0, height = 0;

    double minX() const { return x; }
    double minY() const { return y; }
    double maxX() const { return x + width; }
    double maxY() const { return y + height; }
    Point center() const { return {x + width / 2, y + height / 2}; }
    bool empty() const { return width <= 0 || height <= 0; }
    bool finite() const {
        return std::isfinite(x) && std::isfinite(y) && std::isfinite(width) &&
               std::isfinite(height) && width >= 0 && height >= 0 &&
               std::isfinite(maxX()) && std::isfinite(maxY());
    }
    bool contains(Point p) const {
        return finite() && std::isfinite(p.x) && std::isfinite(p.y) &&
               p.x >= minX() && p.x <= maxX() && p.y >= minY() && p.y <= maxY();
    }
    Point clamp(Point p) const {
        if (!finite() || !std::isfinite(p.x) || !std::isfinite(p.y)) return {};
        return {std::clamp(p.x, minX(), maxX()), std::clamp(p.y, minY(), maxY())};
    }
    Rect intersection(Rect other) const {
        if (!finite() || !other.finite()) return {};
        const double left = std::max(minX(), other.minX());
        const double top = std::max(minY(), other.minY());
        return {left, top, std::max(0.0, std::min(maxX(), other.maxX()) - left),
                           std::max(0.0, std::min(maxY(), other.maxY()) - top)};
    }
};

enum class GeometryError { none, invalidViewSize, invalidDisplayScale, unrepresentable };

// All geometry comes from the current consuming view. Device names, screen
// dimensions, window state, and safe-area guesses do not belong in this layer.
// Logical space is the original landscape presentation: x right, y down.
struct DisplayGeometry {
    static constexpr double OriginalWidth = 480;
    static constexpr double OriginalHeight = 320;
    static constexpr uint32_t DefaultMaximumRasterDimension = 8192;

    bool valid = false;
    GeometryError error = GeometryError::invalidViewSize;
    Size viewSize;
    Size logicalSize;
    Insets safeInsets;                 // Sanitized view points.
    double displayScale = 0;           // Valid input normalized to [1, 3].
    double renderScale = 0;            // Output pixels per view point.
    double pointsPerLogicalUnit = 0;   // Uniform x/y scale, including after resize.
    double pixelsPerLogicalUnit = 0;   // Uniform x/y scale on the output canvas.
    uint32_t rasterWidth = 0;
    uint32_t rasterHeight = 0;
    uint64_t maximumPixels = 0;         // Zero disables the total-pixel budget.
    uint32_t maximumRasterDimension = DefaultMaximumRasterDimension;
    bool budgetLimited = false;        // Either resource limit reduced renderScale.

    Rect viewRect;                     // View points, full drawable bounds.
    Rect logicalRect;                  // Logical space, full drawable bounds.
    Rect originalArtworkRect;          // Centered 480x320 region in logical space.
    Rect safeUIRect;                   // Logical region for reflowed UI anchors.
    Rect originalUIRegion;             // Artwork region intersected with safe UI.
    Rect arenaRect;                    // Full arena, centered in landscape axes.
    Rect guestArenaRect;               // Full arena, rotated original guest axes.

    static DisplayGeometry make(Size viewPoints, double scale,
                                Insets safePoints = {}, uint64_t maxPixels = 0,
                                uint32_t maxRasterDimension = DefaultMaximumRasterDimension) {
        DisplayGeometry result;
        if (!positiveFinite(viewPoints.width) || !positiveFinite(viewPoints.height)) return result;
        if (!positiveFinite(scale)) { result.error = GeometryError::invalidDisplayScale; return result; }

        result.error = GeometryError::unrepresentable;
        result.viewSize = viewPoints;
        result.displayScale = std::clamp(scale, 1.0, 3.0);
        result.maximumPixels = maxPixels;
        result.maximumRasterDimension = maxRasterDimension;
        if (!maxRasterDimension) return result;
        const double widthScale = viewPoints.width / OriginalWidth;
        const double heightScale = viewPoints.height / OriginalHeight;
        result.pointsPerLogicalUnit = std::min(widthScale, heightScale);
        if (!positiveFinite(result.pointsPerLogicalUnit)) return result;
        result.logicalSize = widthScale <= heightScale
            ? Size{OriginalWidth, std::max(OriginalHeight, viewPoints.height / result.pointsPerLogicalUnit)}
            : Size{std::max(OriginalWidth, viewPoints.width / result.pointsPerLogicalUnit), OriginalHeight};
        if (!positiveFinite(result.logicalSize.width) || !positiveFinite(result.logicalSize.height)) return result;

        // Preserve one scale when rounding the pixel canvas. A fractional point
        // size can require less than one pixel of overscan at the right/bottom.
        // Present at rasterViewSize(), aligned top-left and clipped to viewRect;
        // stretching an integer raster to an arbitrary aspect would undo this.
        const double maxDimension = double(maxRasterDimension);
        result.renderScale = std::min({result.displayScale,
            maxDimension / viewPoints.width, maxDimension / viewPoints.height});
        if (!positiveFinite(result.renderScale)) return result;
        result.budgetLimited = result.renderScale < result.displayScale;
        auto dimensions = [&](double candidate, uint32_t& width, uint32_t& height) {
            const double w = std::max(1.0, std::ceil(viewPoints.width * candidate));
            const double h = std::max(1.0, std::ceil(viewPoints.height * candidate));
            if (!positiveFinite(w) || !positiveFinite(h) || w > maxDimension || h > maxDimension) return false;
            width = uint32_t(w); height = uint32_t(h);
            return true;
        };
        const bool withinAxes = dimensions(result.renderScale, result.rasterWidth, result.rasterHeight);
        if (!withinAxes || (maxPixels != 0 && result.pixelCount() > maxPixels)) {
            // Rounding can exceed an axis cap by an ULP, or a total-pixel
            // budget after both dimensions round upward. Check the actual
            // integer canvas while retaining one scale for both axes.
            double low = 0, high = result.renderScale;
            for (unsigned iteration = 0; iteration < 64; ++iteration) {
                const double candidate = low + (high - low) / 2;
                uint32_t width = 0, height = 0;
                if (dimensions(candidate, width, height) &&
                    (maxPixels == 0 || uint64_t(width) * height <= maxPixels)) low = candidate;
                else high = candidate;
            }
            result.renderScale = low;
            result.budgetLimited = true;
            if (!positiveFinite(low) || !dimensions(low, result.rasterWidth, result.rasterHeight)) return result;
        }
        result.pixelsPerLogicalUnit = result.pointsPerLogicalUnit * result.renderScale;
        if (!positiveFinite(result.pixelsPerLogicalUnit)) return result;
        const Size rasterPoints{result.rasterWidth / result.renderScale,
                                result.rasterHeight / result.renderScale};
        if (!positiveFinite(rasterPoints.width) || !positiveFinite(rasterPoints.height)) return result;

        result.safeInsets = sanitizedInsets(safePoints, viewPoints);
        result.viewRect = {0, 0, viewPoints.width, viewPoints.height};
        result.logicalRect = {0, 0, result.logicalSize.width, result.logicalSize.height};
        result.originalArtworkRect = {
            std::max(0.0, (result.logicalSize.width - OriginalWidth) / 2),
            std::max(0.0, (result.logicalSize.height - OriginalHeight) / 2),
            OriginalWidth, OriginalHeight};
        const double safeWidth = std::max(0.0, viewPoints.width - result.safeInsets.left - result.safeInsets.right);
        const double safeHeight = std::max(0.0, viewPoints.height - result.safeInsets.top - result.safeInsets.bottom);
        result.safeUIRect = {result.safeInsets.left / result.pointsPerLogicalUnit,
                            result.safeInsets.top / result.pointsPerLogicalUnit,
                            safeWidth / result.pointsPerLogicalUnit,
                            safeHeight / result.pointsPerLogicalUnit};
        result.originalUIRegion = result.originalArtworkRect.intersection(result.safeUIRect);
        result.arenaRect = {-result.logicalSize.width / 2, -result.logicalSize.height / 2,
                            result.logicalSize.width, result.logicalSize.height};
        result.guestArenaRect = {-result.logicalSize.height / 2, -result.logicalSize.width / 2,
                                 result.logicalSize.height, result.logicalSize.width};
        result.error = GeometryError::none;
        result.valid = true;
        return result;
    }

    uint64_t pixelCount() const { return uint64_t(rasterWidth) * rasterHeight; }
    Size rasterViewSize() const {
        return valid ? Size{rasterWidth / renderScale, rasterHeight / renderScale} : Size{};
    }

    // These conversions intentionally do not clamp: a full-screen game can use
    // the expanded arena. Clamp safeUIRect explicitly only for UI hit targets.
    Point viewToLogical(Point p) const { return valid ? Point{p.x / pointsPerLogicalUnit, p.y / pointsPerLogicalUnit} : Point{}; }
    Point logicalToView(Point p) const { return valid ? Point{p.x * pointsPerLogicalUnit, p.y * pointsPerLogicalUnit} : Point{}; }
    Point logicalToPixel(Point p) const { return valid ? Point{p.x * pixelsPerLogicalUnit, p.y * pixelsPerLogicalUnit} : Point{}; }
    Point pixelToLogical(Point p) const { return valid ? Point{p.x / pixelsPerLogicalUnit, p.y / pixelsPerLogicalUnit} : Point{}; }
    Point originalToLogical(Point p) const { return valid ? Point{p.x + originalArtworkRect.x, p.y + originalArtworkRect.y} : Point{}; }
    Point logicalToOriginal(Point p) const { return valid ? Point{p.x - originalArtworkRect.x, p.y - originalArtworkRect.y} : Point{}; }
    Point originalToView(Point p) const { return logicalToView(originalToLogical(p)); }
    Point viewToOriginal(Point p) const { return logicalToOriginal(viewToLogical(p)); }

    Point logicalToGuest(Point p) const {
        return valid ? Point{p.y - logicalSize.height / 2, p.x - logicalSize.width / 2} : Point{};
    }
    Point guestToLogical(Point p) const {
        return valid ? Point{p.y + logicalSize.width / 2, p.x + logicalSize.height / 2} : Point{};
    }
    Point viewToGuest(Point p) const { return logicalToGuest(viewToLogical(p)); }
    Point guestToView(Point p) const { return logicalToView(guestToLogical(p)); }

    // Snap a text anchor/baseline, rather than independently scaling glyph axes.
    // The movement is at most half a pixel on each axis of the actual canvas.
    Point snapLogicalPointToPixel(Point p) const {
        const Point pixel = logicalToPixel(p);
        if (!valid || !std::isfinite(pixel.x) || !std::isfinite(pixel.y)) return {};
        return pixelToLogical({std::round(pixel.x), std::round(pixel.y)});
    }
    // Result remains in logical units; each edge covers whole output pixels.
    Rect snapLogicalRectOutwardToPixels(Rect rect) const {
        if (!valid || !rect.finite()) return {};
        const Point min = logicalToPixel({rect.minX(), rect.minY()});
        const Point max = logicalToPixel({rect.maxX(), rect.maxY()});
        if (!std::isfinite(min.x) || !std::isfinite(min.y) || !std::isfinite(max.x) || !std::isfinite(max.y)) return {};
        const Point a = pixelToLogical({std::floor(min.x), std::floor(min.y)});
        const Point b = pixelToLogical({std::ceil(max.x), std::ceil(max.y)});
        return {a.x, a.y, b.x - a.x, b.y - a.y};
    }
    uint32_t fontPixelSize(double logicalEm) const {
        const double pixels = logicalEm * pixelsPerLogicalUnit;
        if (!valid || !positiveFinite(logicalEm) || !positiveFinite(pixels)) return 0;
        return uint32_t(std::clamp(std::round(pixels), 1.0, double(std::numeric_limits<uint32_t>::max())));
    }
    double logicalLengthForViewPoints(double points) const {
        return valid && std::isfinite(points) ? points / pointsPerLogicalUnit : 0;
    }

private:
    static bool positiveFinite(double value) { return std::isfinite(value) && value > 0; }
    static Insets sanitizedInsets(Insets insets, Size size) {
        auto edge = [](double value, double limit) {
            if (std::isnan(value) || value <= 0) return 0.0;
            return std::min(value, limit); // Positive infinity becomes the edge limit.
        };
        insets.top = edge(insets.top, size.height); insets.bottom = edge(insets.bottom, size.height);
        insets.left = edge(insets.left, size.width); insets.right = edge(insets.right, size.width);
        auto fitPair = [](double& first, double& second, double limit) {
            const double fraction = first / limit + second / limit;
            if (fraction > 1) { first /= fraction; second /= fraction; }
        };
        fitPair(insets.top, insets.bottom, size.height);
        fitPair(insets.left, insets.right, size.width);
        return insets;
    }
};

} // namespace sdb::display
