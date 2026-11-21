#!/usr/bin/env swift
// Generates ios/App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
// Usage: swift tools/make_icon.swift
import AppKit
import CoreGraphics

let size = 1024
let outputPath = "ios/App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

let space = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("no context") }

// Background gradient (blue to teal).
let colors = [
    CGColor(red: 0.04, green: 0.45, blue: 1.0, alpha: 1),
    CGColor(red: 0.0, green: 0.78, blue: 0.75, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0), options: [])

// White chat bubble.
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
let bubble = CGRect(x: 192, y: 300, width: 640, height: 460)
context.addPath(CGPath(roundedRect: bubble, cornerWidth: 150, cornerHeight: 150, transform: nil))
context.fillPath()
// Tail.
context.move(to: CGPoint(x: 300, y: 330))
context.addLine(to: CGPoint(x: 280, y: 190))
context.addLine(to: CGPoint(x: 450, y: 310))
context.closePath()
context.fillPath()

// Three dots.
context.setFillColor(CGColor(red: 0.04, green: 0.45, blue: 1.0, alpha: 1))
for index in 0..<3 {
    let x = 352 + CGFloat(index) * 160
    context.fillEllipse(in: CGRect(x: x, y: 490, width: 80, height: 80))
}

guard let image = context.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try data.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
