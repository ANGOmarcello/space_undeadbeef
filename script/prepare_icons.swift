#!/usr/bin/env swift
// Created by Angelo Cammalleri on 25.10.2026.
// Export the editable sky and ship layers to tvOS parallax and Top Shelf assets.
// Xcode compiles iOS, macOS and watchOS directly from SpaceUndeadbeef.icon.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconSource = root.appendingPathComponent("Icon Composer/SpaceUndeadbeef.icon/Assets")
func image(_ name: String) -> CGImage {
    let url = iconSource.appendingPathComponent(name)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Missing Icon Composer layer: \(name)")
    }
    return image
}
let sky = image("TitleSky.png")
let ship = image("Ship.png")
guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    fatalError("Cannot create sRGB color space")
}
let info: [String: Any] = ["author": "xcode", "version": 1]
let assets = root.appendingPathComponent("Resources/AppIcons")
// Share the editable document's ship scale. Its canvas is 1024 points.
let documentURL = iconSource.deletingLastPathComponent().appendingPathComponent("icon.json")
let document = try JSONSerialization.jsonObject(with: Data(contentsOf: documentURL)) as! [String: Any]
let groups = document["groups"] as! [[String: Any]]
let shipLayers = groups[0]["layers"] as! [[String: Any]]
let shipPosition = shipLayers.last!["position"] as! [String: Any]
let shipScale = shipPosition["scale"] as! Double
let canvasSide = 1024.0

func json(_ value: [String: Any], at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(10)
    try data.write(to: url, options: .atomic)
}

func png(width: Int, height: Int, at url: URL, foreground: Bool, composite: Bool = false) throws {
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Cannot allocate icon bitmap")
    }
    context.interpolationQuality = .high
    if !foreground || composite {
        // Cover the rectangular TV surface naturally with the continuous sky.
        let cover = max(Double(width) / Double(sky.width), Double(height) / Double(sky.height))
        let size = CGSize(width: Double(sky.width) * cover, height: Double(sky.height) * cover)
        context.draw(sky, in: CGRect(x: (Double(width) - size.width) / 2,
                                    y: (Double(height) - size.height) / 2,
                                    width: size.width, height: size.height))
    }
    if foreground || composite {
        let scale = Double(height) / canvasSide * shipScale
        let size = CGSize(width: Double(ship.width) * scale, height: Double(ship.height) * scale)
        context.draw(ship, in: CGRect(x: (Double(width) - size.width) / 2,
                                     y: (Double(height) - size.height) / 2,
                                     width: size.width, height: size.height))
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot encode icon bitmap")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write icon bitmap") }
}

try json(["info": info], at: assets.appendingPathComponent("tvOS.xcassets/Contents.json"))
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
                    at: directory.appendingPathComponent("Content.imageset/\(filename)"), foreground: layer == "Front")
            images.append(["filename": filename, "idiom": "tv", "scale": "\(scale)x"])
        }
        try json(["images": images, "info": info], at: directory.appendingPathComponent("Content.imageset/Contents.json"))
    }
}
var topShelf: [[String: String]] = []
for scale in [1, 2] {
    let filename = "TopShelf-\(scale)x.png"
    try png(width: 2320 * scale, height: 720 * scale, at: tv.appendingPathComponent("Top Shelf Image Wide.imageset/\(filename)"), foreground: false, composite: true)
    topShelf.append(["filename": filename, "idiom": "tv", "scale": "\(scale)x"])
}
try json(["images": topShelf, "info": info], at: tv.appendingPathComponent("Top Shelf Image Wide.imageset/Contents.json"))
print("Prepared tvOS parallax and Top Shelf assets from the Icon Composer layers.")
