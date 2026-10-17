import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("App/Assets.xcassets")
let info: [String: Any] = ["author": "xcode", "version": 1]

func writeJSON(_ value: [String: Any], at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appendingPathComponent("Contents.json"), options: .atomic)
}

func render(width: Int, height: Int, layer: Int?, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "BoostyAssets", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let rect = NSRect(x: 0, y: 0, width: width, height: height)
    NSColor.clear.setFill()
    rect.fill()
    if layer == nil || layer == 0 {
        NSGradient(starting: NSColor(red: 0.13, green: 0.07, blue: 0.045, alpha: 1),
                   ending: NSColor(red: 0.025, green: 0.035, blue: 0.065, alpha: 1))?.draw(in: rect, angle: -30)
    }
    if layer == nil || layer == 1 {
        NSColor(red: 1, green: 0.34, blue: 0.10, alpha: 1).setFill()
        let size = CGFloat(height) * 0.52
        NSBezierPath(roundedRect: NSRect(x: CGFloat(width) / 2 - size / 2, y: CGFloat(height) * 0.31,
            width: size, height: size), xRadius: size * 0.23, yRadius: size * 0.23).fill()
    }
    if layer == nil || layer == 2 {
        let bFont = NSFont.systemFont(ofSize: CGFloat(height) * 0.41, weight: .black)
        let b = NSAttributedString(string: "B", attributes: [.font: bFont, .foregroundColor: NSColor.white])
        let bSize = b.size()
        b.draw(at: NSPoint(x: CGFloat(width) / 2 - bSize.width / 2,
                          y: CGFloat(height) * 0.55 - bSize.height / 2))
        let title = NSAttributedString(string: "BOOSTY", attributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(height) * 0.09, weight: .bold),
            .foregroundColor: NSColor.white])
        title.draw(at: NSPoint(x: CGFloat(width) / 2 - title.size().width / 2, y: CGFloat(height) * 0.13))
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "BoostyAssets", code: 2)
    }
    try png.write(to: url, options: .atomic)
}

func imageSet(_ directory: URL, width: Int, height: Int, layer: Int?, scales: [Int]) throws {
    var images: [[String: Any]] = []
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for scale in scales {
        let name = "image@\(scale)x.png"
        try render(width: width * scale, height: height * scale, layer: layer,
                   to: directory.appendingPathComponent(name))
        images.append(["idiom": "tv", "filename": name, "scale": "\(scale)x"])
    }
    try writeJSON(["images": images, "info": info], at: directory)
}

try writeJSON(["info": info], at: root)
let brand = root.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
var assets: [[String: Any]] = []
for (name, width, height, scales) in [("App Icon", 400, 240, [1, 2]), ("App Store Icon", 1280, 768, [1])] {
    let stack = brand.appendingPathComponent("\(name).imagestack")
    let names = ["Back", "Middle", "Front"]
    try writeJSON(["layers": names.reversed().map { ["filename": "\($0).imagestacklayer"] }, "info": info], at: stack)
    for (index, layer) in names.enumerated() {
        let directory = stack.appendingPathComponent("\(layer).imagestacklayer")
        try writeJSON(["info": info], at: directory)
        try imageSet(directory.appendingPathComponent("Content.imageset"), width: width,
                     height: height, layer: index, scales: scales)
    }
    assets.append(["size": "\(width)x\(height)", "idiom": "tv", "filename": "\(name).imagestack", "role": "primary-app-icon"])
}
for (name, width, role) in [("Top Shelf Image", 1920, "top-shelf-image"), ("Top Shelf Image Wide", 2320, "top-shelf-image-wide")] {
    try imageSet(brand.appendingPathComponent("\(name).imageset"), width: width, height: 720, layer: nil, scales: [1, 2])
    assets.append(["size": "\(width)x720", "idiom": "tv", "filename": "\(name).imageset", "role": role])
}
try writeJSON(["assets": assets, "info": info], at: brand)
print("Generated tvOS icon layers and Top Shelf assets")
