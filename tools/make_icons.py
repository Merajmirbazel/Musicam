#!/usr/bin/env python3
"""Generates the AppIcon asset sets for both apps from one drawing (needs Xcode's swift and sips)."""
import json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DRAW = r'''
import AppKit
let args = CommandLine.arguments
let full = args[2] == "full"
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = full ? NSRect(x: 0, y: 0, width: size, height: size) : NSRect(x: 100, y: 100, width: 824, height: 824)
let path = full ? NSBezierPath(rect: rect) : NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.45, green: 0.25, blue: 0.95, alpha: 1), NSColor(red: 0.95, green: 0.30, blue: 0.60, alpha: 1), NSColor(red: 1.0, green: 0.60, blue: 0.25, alpha: 1)])!.draw(in: path, angle: -45)
let cfg = NSImage.SymbolConfiguration(pointSize: full ? 520 : 430, weight: .bold)
let sym = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
let tinted = NSImage(size: sym.size)
tinted.lockFocus()
sym.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
NSColor.white.set()
NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop)
tinted.unlockFocus()
tinted.draw(at: NSPoint(x: (CGFloat(size) - sym.size.width) / 2, y: (CGFloat(size) - sym.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
'''

def draw(out, mode):
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "draw.swift")
        open(src, "w").write(DRAW)
        subprocess.run(["swift", src, out, mode], check=True)

def write_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)

def catalog(app_dir):
    cat = os.path.join(ROOT, app_dir, "Assets.xcassets")
    icon = os.path.join(cat, "AppIcon.appiconset")
    os.makedirs(icon, exist_ok=True)
    write_json(os.path.join(cat, "Contents.json"), {"info": {"author": "xcode", "version": 1}})
    return icon

# iOS: one full-bleed 1024 icon; the system applies the mask.
ios = catalog("App-iOS")
ios_png = os.path.join(ios, "icon-1024.png")
draw(ios_png, "full")
# iOS icons must not carry an alpha channel: a round trip through JPEG drops it
jpg = ios_png + ".jpg"
subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "100", ios_png, "--out", jpg], check=True, stdout=subprocess.DEVNULL)
subprocess.run(["sips", "-s", "format", "png", jpg, "--out", ios_png], check=True, stdout=subprocess.DEVNULL)
os.remove(jpg)
write_json(os.path.join(ios, "Contents.json"), {
    "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
    "info": {"author": "xcode", "version": 1}})

# macOS: the rounded icon in all required sizes.
mac = catalog("App-macOS")
master = os.path.join(mac, "master-1024.png")
draw(master, "rounded")
images = []
for base in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = base * scale
        name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
        subprocess.run(["sips", "-z", str(px), str(px), master, "--out", os.path.join(mac, name)],
                       check=True, stdout=subprocess.DEVNULL)
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{base}x{base}"})
os.remove(master)
write_json(os.path.join(mac, "Contents.json"), {"images": images, "info": {"author": "xcode", "version": 1}})
print("icons written")
