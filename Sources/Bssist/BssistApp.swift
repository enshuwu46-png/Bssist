import SwiftUI
import AppKit

@main
struct BssistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Bssist") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 520, height: 600)
    }
}

/// Custom vector Bilibili Little TV icon for use inside SwiftUI views
struct BiliTVIcon: View {
    var size: CGFloat = 20

    var body: some View {
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            let stroke = max(1.3, s * 0.095)

            // TV Body
            let tvW = s * 0.78
            let tvH = s * 0.56
            let tvX = (s - tvW) * 0.5
            let tvY = s * 0.28
            let tvRect = CGRect(x: tvX, y: tvY, width: tvW, height: tvH)
            let tvRadius = s * 0.14

            var bodyPath = Path()
            bodyPath.addRoundedRect(in: tvRect, cornerSize: CGSize(width: tvRadius, height: tvRadius))

            // Antennas
            bodyPath.move(to: CGPoint(x: s * 0.38, y: tvY))
            bodyPath.addLine(to: CGPoint(x: s * 0.23, y: s * 0.10))
            bodyPath.move(to: CGPoint(x: s * 0.62, y: tvY))
            bodyPath.addLine(to: CGPoint(x: s * 0.77, y: s * 0.10))

            // Feet
            let bottomY = tvY + tvH
            bodyPath.move(to: CGPoint(x: s * 0.30, y: bottomY))
            bodyPath.addLine(to: CGPoint(x: s * 0.30, y: bottomY + s * 0.06))
            bodyPath.move(to: CGPoint(x: s * 0.70, y: bottomY))
            bodyPath.addLine(to: CGPoint(x: s * 0.70, y: bottomY + s * 0.06))

            // Slanted eyes
            bodyPath.move(to: CGPoint(x: s * 0.27, y: s * 0.49))
            bodyPath.addLine(to: CGPoint(x: s * 0.40, y: s * 0.56))
            bodyPath.move(to: CGPoint(x: s * 0.73, y: s * 0.49))
            bodyPath.addLine(to: CGPoint(x: s * 0.60, y: s * 0.56))

            context.stroke(
                bodyPath,
                with: .foreground,
                style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: size, height: size)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let iconImage: NSImage? = {
            if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let img = NSImage(contentsOf: icnsURL) {
                return img
            }
            return Self.makeBiliStyleDockIcon(size: 512)
        }()

        if let iconImage {
            NSApp.applicationIconImage = iconImage
            let bundlePath = Bundle.main.bundlePath
            if bundlePath.hasSuffix(".app") {
                NSWorkspace.shared.setIcon(iconImage, forFile: bundlePath, options: [])
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    static func makeBiliStyleDockIcon(size: Int) -> NSImage? {
        let s = CGFloat(size)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let inset = s * 0.095
        let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let radius = rect.width * 0.225
        let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        let bgColors = [
            CGColor(red: 0.15, green: 0.15, blue: 0.16, alpha: 1.0),
            CGColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1.0)
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: s * 0.5, y: s - inset),
                end: CGPoint(x: s * 0.5, y: inset),
                options: []
            )
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
        ctx.setLineWidth(max(1.0, s * 0.012))
        ctx.strokePath()
        ctx.restoreGState()

        let white = CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)
        ctx.setStrokeColor(white)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let strokeW = max(1.5, s * 0.052)
        ctx.setLineWidth(strokeW)

        let tvWidth = s * 0.54
        let tvHeight = s * 0.39
        let tvX = (s - tvWidth) * 0.5
        let tvY = s * 0.24
        let tvRect = CGRect(x: tvX, y: tvY, width: tvWidth, height: tvHeight)
        let tvCorner = s * 0.095
        let tvPath = CGPath(roundedRect: tvRect, cornerWidth: tvCorner, cornerHeight: tvCorner, transform: nil)
        ctx.addPath(tvPath)
        ctx.strokePath()

        let topY = tvY + tvHeight
        ctx.move(to: CGPoint(x: s * 0.42, y: topY))
        ctx.addLine(to: CGPoint(x: s * 0.31, y: s * 0.745))
        ctx.move(to: CGPoint(x: s * 0.58, y: topY))
        ctx.addLine(to: CGPoint(x: s * 0.69, y: s * 0.745))
        ctx.strokePath()

        ctx.setLineWidth(max(1.2, s * 0.044))
        ctx.move(to: CGPoint(x: s * 0.35, y: tvY))
        ctx.addLine(to: CGPoint(x: s * 0.35, y: tvY - s * 0.038))
        ctx.move(to: CGPoint(x: s * 0.65, y: tvY))
        ctx.addLine(to: CGPoint(x: s * 0.65, y: tvY - s * 0.038))
        ctx.strokePath()

        ctx.setLineWidth(max(1.4, s * 0.046))
        ctx.move(to: CGPoint(x: s * 0.34, y: s * 0.485))
        ctx.addLine(to: CGPoint(x: s * 0.43, y: s * 0.435))
        ctx.move(to: CGPoint(x: s * 0.66, y: s * 0.485))
        ctx.addLine(to: CGPoint(x: s * 0.57, y: s * 0.435))
        ctx.strokePath()

        ctx.setLineWidth(max(1.2, s * 0.036))
        ctx.move(to: CGPoint(x: s * 0.455, y: s * 0.365))
        ctx.addLine(to: CGPoint(x: s * 0.50, y: s * 0.325))
        ctx.addLine(to: CGPoint(x: s * 0.545, y: s * 0.365))
        ctx.strokePath()

        guard let cgImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: s, height: s))
    }
}
