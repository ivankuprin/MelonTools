import AppKit

// Trim transparent margins from a PNG logo and add a small uniform pad.
// Usage: swift trim-logo.swift <in.png> <out.png> [padFraction]

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: trim-logo.swift <in.png> <out.png> [pad]\n".utf8))
    exit(2)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let padFraction = args.count > 3 ? (Double(args[3]) ?? 0.04) : 0.04

guard let image = NSImage(contentsOf: inURL),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8))
    exit(1)
}

let w = cg.width
let h = cg.height
guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { exit(1) }
let bpp = cg.bitsPerPixel / 8
let rowBytes = cg.bytesPerRow

var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    let row = ptr + y * rowBytes
    for x in 0..<w {
        if row[x * bpp + 3] > 8 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
}
guard maxX >= minX, maxY >= minY else {
    FileHandle.standardError.write(Data("empty alpha bounding box\n".utf8))
    exit(1)
}

let bw = maxX - minX + 1
let bh = maxY - minY + 1
let padPx = Int((Double(max(bw, bh)) * padFraction).rounded())
let cropW = min(w, bw + padPx * 2)
let cropH = min(h, bh + padPx * 2)
let originX = max(0, min(minX - padPx, w - cropW))
let originY = max(0, min(minY - padPx, h - cropH))

guard let cropped = cg.cropping(to: CGRect(x: originX, y: originY, width: cropW, height: cropH)) else { exit(1) }
let rep = NSBitmapImageRep(cgImage: cropped)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: outURL)
print("trimmed \(w)x\(h) -> \(cropW)x\(cropH)")
