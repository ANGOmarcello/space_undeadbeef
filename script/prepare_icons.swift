#!/usr/bin/env swift
// Created by Angelo Cammalleri on 25.10.2026.
// Package the original pixel artwork at Apple's required raster icon sizes.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = root.appendingPathComponent("Resources/Original/icon.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    fatalError("The prepared original icon is missing or invalid")
}
let info: [String: Any] = ["author": "xcode", "version": 1]
let assets = root.appendingPathComponent("Resources/AppIcons")

func json(_ value: [String: Any], at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(10)
    try data.write(to: url, options: .atomic)
}

func png(width: Int, height: Int, at url: URL, transparent: Bool = false) throws {
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: (transparent ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue) else {
        fatalError("Cannot allocate icon bitmap")
    }
    if !transparent {
        // Extend the edge columns for rectangular TV assets. The ship keeps its
        // original proportions, and the source's background remains continuous.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        let side = min(width, height)
        let inset = (width - side) / 2
        if inset > 0 {
            let left = artwork.cropping(to: CGRect(x: 0, y: 0, width: 1, height: artwork.height))!
            let right = artwork.cropping(to: CGRect(x: artwork.width - 1, y: 0, width: 1, height: artwork.height))!
            context.draw(left, in: CGRect(x: 0, y: 0, width: inset, height: height))
            context.draw(right, in: CGRect(x: inset + side, y: 0, width: width - inset - side, height: height))
        }
        context.draw(artwork, in: CGRect(x: inset, y: 0, width: side, height: height))
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot encode icon bitmap")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write icon bitmap") }
}

for platform in ["iOS", "watchOS", "macOS", "tvOS"] {
    try json(["info": info], at: assets.appendingPathComponent("\(platform).xcassets/Contents.json"))
}
for platform in ["iOS", "watchOS"] {
    let icon = assets.appendingPathComponent("\(platform).xcassets/AppIcon.appiconset")
    try png(width: 1024, height: 1024, at: icon.appendingPathComponent("AppIcon-1024.png"))
    try json(["images": [["filename": "AppIcon-1024.png", "idiom": "universal",
                            "platform": platform.lowercased(), "size": "1024x1024"]],
              "info": info], at: icon.appendingPathComponent("Contents.json"))
}

let macIcon = assets.appendingPathComponent("macOS.xcassets/AppIcon.appiconset")
var macImages: [[String: String]] = []
var generatedSizes = Set<Int>()
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let filename = "AppIcon-\(pixels).png"
        if generatedSizes.insert(pixels).inserted {
            try png(width: pixels, height: pixels, at: macIcon.appendingPathComponent(filename))
        }
        macImages.append(["filename": filename, "idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x"])
    }
}
try json(["images": macImages, "info": info], at: macIcon.appendingPathComponent("Contents.json"))

let tv = assets.appendingPathComponent("tvOS.xcassets/AppIcon.brandassets")
try json(["assets": [
    ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
    ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
    ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"]
], "info": info], at: tv.appendingPathComponent("Contents.json"))
for (name, width, height, scales) in [("App Icon", 400, 240, [1, 2]), ("App Icon - App Store", 1280, 768, [1])] {
    let stack = tv.appendingPathComponent("\(name).imagestack")
    try json(["layers": [["filename": "Front.imagestacklayer"], ["filename": "Back.imagestacklayer"]],
              "info": info], at: stack.appendingPathComponent("Contents.json"))
    for layer in ["Front", "Back"] {
        let directory = stack.appendingPathComponent("\(layer).imagestacklayer")
        try json(["info": info], at: directory.appendingPathComponent("Contents.json"))
        var images: [[String: String]] = []
        for scale in scales {
            let filename = "\(layer)-\(scale)x.png"
            try png(width: width * scale, height: height * scale,
                    at: directory.appendingPathComponent("Content.imageset/\(filename)"), transparent: layer == "Front")
            images.append(["filename": filename, "idiom": "tv", "scale": "\(scale)x"])
        }
        try json(["images": images, "info": info], at: directory.appendingPathComponent("Content.imageset/Contents.json"))
    }
}
var topShelf: [[String: String]] = []
for scale in [1, 2] {
    let filename = "TopShelf-\(scale)x.png"
    try png(width: 2320 * scale, height: 720 * scale, at: tv.appendingPathComponent("Top Shelf Image Wide.imageset/\(filename)"))
    topShelf.append(["filename": filename, "idiom": "tv", "scale": "\(scale)x"])
}
try json(["images": topShelf, "info": info], at: tv.appendingPathComponent("Top Shelf Image Wide.imageset/Contents.json"))
print("Prepared four platform icon catalogs from the original 57×57 artwork.")
