//
//  Glitter — a system-wide sparkle trail for macOS
//
//  A transparent, click-through overlay window floats above every app and
//  draws particles wherever your cursor goes. Lives in the menu bar.
//
//  No accessibility permissions needed: the cursor position is polled with
//  NSEvent.mouseLocation rather than intercepted with an event tap.
//
//  Build:  ./build.sh     Run:  open Glitter.app     Quit: menu bar ✨ → Quit
//

import Cocoa
import QuartzCore

// MARK: - Tunables

/// Every value below can be overridden without recompiling, e.g.:
///   defaults write local.glitter.cursor birthRate -float 400
///   defaults write local.glitter.cursor gravity -float -220
/// Delete an override to fall back to the built-in default:
///   defaults delete local.glitter.cursor birthRate
private extension UserDefaults {
    func tunable(_ key: String, _ fallback: Float) -> Float {
        object(forKey: key) != nil ? float(forKey: key) : fallback
    }
    func tunable(_ key: String, _ fallback: CGFloat) -> CGFloat {
        object(forKey: key) != nil ? CGFloat(double(forKey: key)) : fallback
    }
}

enum Config {
    private static let d = UserDefaults.standard

    static var birthRate: Float = d.tunable("birthRate", 240)              // specks per second while moving
    static var lifetime: Float = d.tunable("lifetime", 1.25)               // seconds a speck survives
    static var scale: CGFloat = d.tunable("scale", 0.42)                   // base speck size
    static var gravity: CGFloat = d.tunable("gravity", -140)               // negative pulls specks downward
    static var velocity: CGFloat = d.tunable("velocity", 34)               // initial outward push
    static var spin: CGFloat = d.tunable("spin", 3.0)                      // radians per second
    static var minSpeed: CGFloat = d.tunable("minSpeed", 0.6)              // cursor speed below this = no glitter
    static var speedForFullRate: CGFloat = d.tunable("speedForFullRate", 26)
}

enum Palette: String, CaseIterable {
    case party = "Party"
    case gold = "Gold rush"
    case frost = "Frost"
    case rainbow = "Rainbow"

    var colors: [NSColor] {
        switch self {
        case .party:
            return [hex(0xffd166), hex(0xff5fa2), hex(0x63e6e2), hex(0xc084fc), .white]
        case .gold:
            return [hex(0xffd166), hex(0xf6b73c), hex(0xfff3c4), hex(0xe8a33d), .white]
        case .frost:
            return [hex(0xa5f3fc), hex(0xe0f2fe), hex(0x7dd3fc), hex(0xc4b5fd), .white]
        case .rainbow:
            return [hex(0xff5f6d), hex(0xffc371), hex(0x8de969), hex(0x63e6e2), hex(0x7aa2ff), hex(0xc084fc)]
        }
    }

    private func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255,
                alpha: 1)
    }
}

// MARK: - Persisted state

/// Keeps the on/off toggle and chosen palette across launches.
private enum Prefs {
    private static let d = UserDefaults.standard
    private static let onKey = "GlitterOn"
    private static let paletteKey = "GlitterPalette"

    static var isOn: Bool {
        get { d.object(forKey: onKey) != nil ? d.bool(forKey: onKey) : true }
        set { d.set(newValue, forKey: onKey) }
    }

    static var palette: Palette {
        get { Palette(rawValue: d.string(forKey: paletteKey) ?? "") ?? .party }
        set { d.set(newValue.rawValue, forKey: paletteKey) }
    }
}

// MARK: - Speck artwork

/// A soft four-point star, drawn once and reused as the particle texture.
func sparkleTexture(_ side: Int = 48) -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil,
                        width: side, height: side,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    let s = CGFloat(side), c = s / 2

    // Glow core
    let gradient = CGGradient(colorsSpace: space,
                              colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.95),
                                       CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                              locations: [0, 1])!
    ctx.drawRadialGradient(gradient,
                           startCenter: CGPoint(x: c, y: c), startRadius: 0,
                           endCenter: CGPoint(x: c, y: c), endRadius: c * 0.5,
                           options: [])

    // Star: four concave spikes pinched toward the middle
    let star = CGMutablePath()
    let mid = CGPoint(x: c, y: c)
    star.move(to: CGPoint(x: c, y: 0))
    star.addQuadCurve(to: CGPoint(x: s, y: c), control: mid)
    star.addQuadCurve(to: CGPoint(x: c, y: s), control: mid)
    star.addQuadCurve(to: CGPoint(x: 0, y: c), control: mid)
    star.addQuadCurve(to: CGPoint(x: c, y: 0), control: mid)
    star.closeSubpath()

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(star)
    ctx.fillPath()

    return ctx.makeImage()!
}

// MARK: - Overlay window

final class OverlayWindow: NSWindow {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true            // clicks pass straight through
        isReleasedWhenClosed = false
        // .statusBar sits above normal app windows (and, combined with
        // .fullScreenAuxiliary below, above full-screen apps too) without
        // reaching all the way up to .screenSaver, which can paint over
        // system UI like Spotlight or notification banners.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.isOpaque = false
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: OverlayWindow!
    private var emitter = CAEmitterLayer()
    private let texture = sparkleTexture()
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private var lastPoint = NSEvent.mouseLocation
    private var palette: Palette = Prefs.palette
    private var isOn: Bool = Prefs.isOn

    func applicationDidFinishLaunching(_ note: Notification) {
        buildWindow()
        buildMenuBar()
        start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    // Union of every attached display, so one window covers the whole desk.
    private var deskFrame: NSRect {
        guard let first = NSScreen.screens.first else { return .zero }
        return NSScreen.screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }

    private func buildWindow() {
        let frame = deskFrame
        window = OverlayWindow(frame: frame)

        emitter.frame = CGRect(origin: .zero, size: frame.size)
        emitter.emitterShape = .point
        emitter.emitterMode = .points
        emitter.renderMode = .additive       // specks glow where they overlap
        emitter.birthRate = 0                // multiplier, driven by cursor speed
        emitter.emitterCells = makeCells()

        window.contentView?.layer?.addSublayer(emitter)
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
    }

    private func makeCells() -> [CAEmitterCell] {
        palette.colors.map { color in
            let cell = CAEmitterCell()
            cell.contents = texture
            cell.color = color.cgColor
            cell.birthRate = Config.birthRate / Float(palette.colors.count)
            cell.lifetime = Config.lifetime
            cell.lifetimeRange = Config.lifetime * 0.4

            cell.velocity = Config.velocity
            cell.velocityRange = Config.velocity * 1.3
            cell.emissionRange = .pi * 2
            cell.yAcceleration = Config.gravity
            cell.xAcceleration = 0

            cell.scale = Config.scale
            cell.scaleRange = Config.scale * 0.7
            cell.scaleSpeed = -Config.scale * 0.55

            cell.spin = Config.spin
            cell.spinRange = Config.spin * 2

            cell.alphaSpeed = -1.0 / Config.lifetime
            return cell
        }
    }

    private func buildMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✨"

        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Glitter", action: #selector(toggleGlitter), keyEquivalent: "")
        toggle.target = self
        toggle.state = isOn ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())

        let paletteItem = NSMenuItem(title: "Palette", action: nil, keyEquivalent: "")
        let paletteMenu = NSMenu()
        for p in Palette.allCases {
            let item = NSMenuItem(title: p.rawValue, action: #selector(choosePalette(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p.rawValue
            item.state = (p == palette) ? .on : .off
            paletteMenu.addItem(item)
        }
        paletteItem.submenu = paletteMenu
        menu.addItem(paletteItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Glitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func start() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // keeps running while menus are open
        timer = t
    }

    private func tick() {
        guard isOn else { return }

        let p = NSEvent.mouseLocation
        let dx = p.x - lastPoint.x, dy = p.y - lastPoint.y
        let speed = (dx * dx + dy * dy).squareRoot()
        lastPoint = p

        // Screen coords → window coords
        let origin = window.frame.origin
        let local = CGPoint(x: p.x - origin.x, y: p.y - origin.y)

        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no implicit tweening on position
        emitter.emitterPosition = local
        emitter.birthRate = speed < Config.minSpeed
            ? 0
            : Float(min(speed / Config.speedForFullRate, 1.6))
        CATransaction.commit()
    }

    @objc private func toggleGlitter(_ sender: NSMenuItem) {
        isOn.toggle()
        Prefs.isOn = isOn
        sender.state = isOn ? .on : .off
        if !isOn {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            emitter.birthRate = 0
            CATransaction.commit()
        }
    }

    @objc private func choosePalette(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let picked = Palette(rawValue: raw) else { return }
        palette = picked
        Prefs.palette = picked
        sender.menu?.items.forEach { $0.state = ($0 === sender) ? .on : .off }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.emitterCells = makeCells()
        CATransaction.commit()
    }

    @objc private func screensChanged() {
        let frame = deskFrame
        window.setFrame(frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = CGRect(origin: .zero, size: frame.size)
        CATransaction.commit()
    }
}

// MARK: - Launch

let app = NSApplication.shared
app.setActivationPolicy(.accessory)     // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
