//
//  Glitter — a system-wide cursor overlay for macOS: sparkle trails, a
//  click-ripple / spotlight / laser pointer, and click-and-drag
//  annotations for screen-shared demos and training.
//
//  A transparent, click-through overlay window floats above every app and
//  draws pointer effects wherever your cursor goes. Toggle "Annotate Mode"
//  from the menu bar to switch the window from click-through to
//  click-capturing, so you can draw on top of whatever you're presenting;
//  toggle it off to resume normal interaction with the app underneath.
//
//  No special permissions needed: cursor position is polled with
//  NSEvent.mouseLocation, clicks are observed with a global mouse monitor,
//  and every hotkey below is registered with the old Carbon Hot Key API
//  (RegisterEventHotKey) — none of these require Accessibility or Input
//  Monitoring access. (NSEvent's global *keyboard* monitor would require
//  Input Monitoring, which is why the hotkeys go through Carbon instead:
//  it registers one specific combo with the OS rather than watching every
//  keystroke, so no prompt is needed.)
//
//  Hotkeys (work system-wide, while any app is focused):
//    ⌃⌥1  Glitter          ⌃⌥2  Click Ripple
//    ⌃⌥3  Spotlight        ⌃⌥4  Laser Pointer
//    ⌃⌥5  Normal (no effect)
//    ⌃⌥A  Toggle Annotate Mode
//    ⌃⌥C  Clear Annotations
//
//  Build:  ./build.sh     Run:  open Glitter.app     Quit: menu bar ✨ → Quit
//

import Cocoa
import QuartzCore
import Carbon.HIToolbox

// MARK: - Tunables

/// Every value below can be overridden without recompiling, e.g.:
///   defaults write local.glitter.cursor birthRate -float 400
///   defaults write local.glitter.cursor spotlightRadius -float 180
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

    // Glitter effect
    static var birthRate: Float = d.tunable("birthRate", 240)              // specks per second while moving
    static var lifetime: Float = d.tunable("lifetime", 1.25)               // seconds a speck survives
    static var scale: CGFloat = d.tunable("scale", 0.42)                   // base speck size
    static var gravity: CGFloat = d.tunable("gravity", -140)               // negative pulls specks downward
    static var velocity: CGFloat = d.tunable("velocity", 34)               // initial outward push
    static var spin: CGFloat = d.tunable("spin", 3.0)                      // radians per second
    static var minSpeed: CGFloat = d.tunable("minSpeed", 0.6)              // cursor speed below this = no glitter
    static var speedForFullRate: CGFloat = d.tunable("speedForFullRate", 26)

    // Spotlight effect
    static var spotlightRadius: CGFloat = d.tunable("spotlightRadius", 130)
    static var spotlightDim: CGFloat = d.tunable("spotlightDim", 0.55)     // 0-1, how dark the surrounding area is

    // Click ripple / laser pointer
    static var rippleMaxRadius: CGFloat = d.tunable("rippleMaxRadius", 46)
    static var rippleDuration: Float = d.tunable("rippleDuration", 0.5)
    static var laserDotRadius: CGFloat = d.tunable("laserDotRadius", 7)

    // Annotations
    static var annotationWidth: CGFloat = d.tunable("annotationWidth", 4)
}

/// Signal color for the ripple/laser pointer — deliberately fixed (not a
/// Palette color) so it always reads as "presenter pointer," not "party."
private let pointerColor = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)

enum Palette: String, CaseIterable {
    case party = "Party"
    case gold = "Gold rush"
    case frost = "Frost"
    case rainbow = "Rainbow"
    case dragon = "Dragon's Breath"

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
        case .dragon:
            return [hex(0x8b0000), hex(0xd7263d), hex(0xff6b35), hex(0xffb703), hex(0xfff3b0)]
        }
    }

    private func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255,
                alpha: 1)
    }
}

/// What the cursor draws as you move it. Only one is active at a time.
enum PointerEffect: String, CaseIterable {
    case none = "Normal"
    case glitter = "Glitter"
    case ripple = "Click Ripple"
    case spotlight = "Spotlight"
    case laser = "Laser Pointer"
}

enum AnnotationColor: String, CaseIterable {
    case red = "Red"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case white = "White"

    var color: NSColor {
        switch self {
        case .red: return NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
        case .yellow: return NSColor(srgbRed: 1, green: 0.80, blue: 0.0, alpha: 1)
        case .green: return NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1)
        case .white: return .white
        }
    }
}

/// .pointer: click-through, draws pointer effects (today's default).
/// .annotate: captures clicks itself so you can draw; nothing reaches the
/// app underneath until you switch back.
enum Mode {
    case pointer
    case annotate
}

// MARK: - Persisted state

/// Keeps preferences across launches. Mode is intentionally NOT persisted —
/// every launch starts in .pointer so you never accidentally open into a
/// state where clicks don't reach your other apps.
private enum Prefs {
    private static let d = UserDefaults.standard
    private static let onKey = "GlitterOn"
    private static let paletteKey = "GlitterPalette"
    private static let effectKey = "GlitterEffect"
    private static let annotationColorKey = "GlitterAnnotationColor"

    static var isOn: Bool {
        get { d.object(forKey: onKey) != nil ? d.bool(forKey: onKey) : true }
        set { d.set(newValue, forKey: onKey) }
    }

    static var palette: Palette {
        get { Palette(rawValue: d.string(forKey: paletteKey) ?? "") ?? .party }
        set { d.set(newValue.rawValue, forKey: paletteKey) }
    }

    static var effect: PointerEffect {
        get { PointerEffect(rawValue: d.string(forKey: effectKey) ?? "") ?? .glitter }
        set { d.set(newValue.rawValue, forKey: effectKey) }
    }

    static var annotationColor: AnnotationColor {
        get { AnnotationColor(rawValue: d.string(forKey: annotationColorKey) ?? "") ?? .red }
        set { d.set(newValue.rawValue, forKey: annotationColorKey) }
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

// MARK: - Annotation drawing

protocol AnnotationDrawing: AnyObject {
    func annotationBegin(at point: CGPoint)
    func annotationDrag(to point: CGPoint)
    func annotationEnd()
}

// MARK: - Overlay window

final class OverlayContentView: NSView {
    weak var annotationDelegate: AnnotationDrawing?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        annotationDelegate?.annotationBegin(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) {
        annotationDelegate?.annotationDrag(to: convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        annotationDelegate?.annotationEnd()
    }
}

final class OverlayWindow: NSWindow {
    /// Called when Escape is pressed while this window is key. A guaranteed
    /// way out of Annotate Mode: it works purely through window key status,
    /// not hit-testing geometry, so it can't be blocked by the overlay
    /// covering something it shouldn't (see deskFrame's menu-bar exclusion
    /// for the other half of that fix).
    var onEscape: (() -> Void)?

    /// Scopes canBecomeKey to exactly when it's needed (Annotate Mode),
    /// rather than being unconditionally true, to keep .pointer mode's
    /// behavior as close to the original click-through-only design as
    /// possible.
    var isAnnotating: () -> Bool = { false }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true            // clicks pass straight through in .pointer mode
        isReleasedWhenClosed = false
        // .statusBar sits above normal app windows (and, combined with
        // .fullScreenAuxiliary below, above full-screen apps too) without
        // reaching all the way up to .screenSaver, which can paint over
        // system UI like Spotlight or notification banners.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = OverlayContentView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]   // track window size across display changes
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.isOpaque = false
        contentView = view
    }

    // True only while Annotate Mode is active, so it can receive Escape via
    // keyDown below. Costs no permission (a window becoming key in its own
    // app is completely normal) and leaves .pointer mode's key-window
    // behavior untouched from before.
    override var canBecomeKey: Bool { isAnnotating() }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Escape
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, AnnotationDrawing {

    private var window: OverlayWindow!
    private var emitter = CAEmitterLayer()
    private let texture = sparkleTexture()
    private var statusItem: NSStatusItem!
    private var annotateMenuItem: NSMenuItem?
    private var effectMenu: NSMenu?
    private var timer: Timer?
    private var clickMonitor: Any?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var hotKeyActions: [UInt32: () -> Void] = [:]

    private var rippleContainer = CALayer()
    private var spotlightLayer = CAShapeLayer()
    private var laserDot = CAShapeLayer()
    private var annotationLayer = CALayer()
    private var strokeLayers: [CAShapeLayer] = []
    private var currentStroke: (path: CGMutablePath, layer: CAShapeLayer)?

    private var lastPoint = NSEvent.mouseLocation
    private var palette: Palette = Prefs.palette
    private var effect: PointerEffect = Prefs.effect
    private var annotationColor: AnnotationColor = Prefs.annotationColor
    private var isOn: Bool = Prefs.isOn
    private var mode: Mode = .pointer

    func applicationDidFinishLaunching(_ note: Notification) {
        buildWindow()
        buildMenuBar()
        start()
        installClickMonitor()
        installHotKeys()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        for ref in hotKeyRefs {
            if let ref = ref { UnregisterEventHotKey(ref) }
        }
    }

    // Union of every attached display, so one window covers the whole desk —
    // minus a strip across the top equal to the menu bar's height, so the
    // overlay can never claim clicks meant for the menu bar or any status
    // item (including our own ✨ icon). Without this, Annotate Mode's
    // click-capturing can make the menu bar itself unclickable, with no way
    // back in. (Belt-and-suspenders: Escape also force-exits Annotate Mode
    // regardless of this geometry — see OverlayWindow.onEscape.)
    private var deskFrame: NSRect {
        guard let first = NSScreen.screens.first else { return .zero }
        let union = NSScreen.screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        // Clamped to a plausible menu-bar-height range (24-38pt on real
        // Macs) so an unusual screen/Dock arrangement can't collapse or
        // distort the whole overlay -- worst case we just don't exclude
        // the strip, rather than break everything.
        let menuBarHeight = min(max(first.frame.maxY - first.visibleFrame.maxY, 0), 60)
        return NSRect(x: union.minX, y: union.minY,
                      width: union.width, height: union.height - menuBarHeight)
    }

    private func buildWindow() {
        let frame = deskFrame
        window = OverlayWindow(frame: frame)
        (window.contentView as? OverlayContentView)?.annotationDelegate = self

        guard let rootLayer = window.contentView?.layer else { return }

        emitter.frame = CGRect(origin: .zero, size: frame.size)
        emitter.emitterShape = .point
        emitter.emitterMode = .points
        emitter.renderMode = .additive       // specks glow where they overlap
        emitter.birthRate = 0                // multiplier, driven by cursor speed
        emitter.emitterCells = makeCells()
        rootLayer.addSublayer(emitter)

        rippleContainer.frame = CGRect(origin: .zero, size: frame.size)
        rootLayer.addSublayer(rippleContainer)

        laserDot.fillColor = pointerColor.cgColor
        laserDot.shadowColor = pointerColor.cgColor
        laserDot.shadowRadius = 8
        laserDot.shadowOpacity = 0.9
        laserDot.shadowOffset = .zero
        laserDot.isHidden = true
        rootLayer.addSublayer(laserDot)

        spotlightLayer.frame = CGRect(origin: .zero, size: frame.size)
        spotlightLayer.fillColor = NSColor.black.withAlphaComponent(Config.spotlightDim).cgColor
        spotlightLayer.fillRule = .evenOdd
        spotlightLayer.isHidden = true
        rootLayer.addSublayer(spotlightLayer)

        annotationLayer.frame = CGRect(origin: .zero, size: frame.size)
        rootLayer.addSublayer(annotationLayer)   // drawn last: always on top

        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        window.onEscape = { [weak self] in self?.exitAnnotateMode() }
        window.isAnnotating = { [weak self] in self?.mode == .annotate }
        applyEffectVisibility()
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

    /// Briefly shows text in the menu bar instead of ✨ — an unmissable,
    /// immediate confirmation that a hotkey (or menu click) actually
    /// registered, without needing to open the menu or check Console.app.
    private func flashStatusItem(_ text: String) {
        statusItem.button?.title = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.statusItem.button?.title = "✨"
        }
    }

    /// Shows/hides each effect's layer to match the current selection.
    /// Does not touch Annotate mode's layers.
    private func applyEffectVisibility() {
        emitter.isHidden = effect != .glitter
        if effect != .glitter { emitter.birthRate = 0 }
        laserDot.isHidden = effect != .laser
        spotlightLayer.isHidden = effect != .spotlight
    }

    private func buildMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✨"

        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Cursor Effects", action: #selector(toggleEffects), keyEquivalent: "")
        toggle.target = self
        toggle.state = isOn ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())

        let effectItem = NSMenuItem(title: "Effect", action: nil, keyEquivalent: "")
        let effectMenu = NSMenu()
        let effectHotkeys: [PointerEffect: String] = [.glitter: "1", .ripple: "2", .spotlight: "3", .laser: "4", .none: "5"]
        for e in PointerEffect.allCases {
            let item = NSMenuItem(title: e.rawValue, action: #selector(chooseEffect(_:)), keyEquivalent: effectHotkeys[e] ?? "")
            item.keyEquivalentModifierMask = [.control, .option]   // display only — the real binding is the Carbon hotkey below
            item.target = self
            item.representedObject = e.rawValue
            item.state = (e == effect) ? .on : .off
            effectMenu.addItem(item)
        }
        effectItem.submenu = effectMenu
        self.effectMenu = effectMenu
        menu.addItem(effectItem)

        let paletteItem = NSMenuItem(title: "Glitter Palette", action: nil, keyEquivalent: "")
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

        let annotate = NSMenuItem(title: "Annotate Mode", action: #selector(toggleAnnotateMode(_:)), keyEquivalent: "a")
        annotate.keyEquivalentModifierMask = [.control, .option]   // display only — real binding is the Carbon hotkey
        annotate.target = self
        annotate.state = .off
        menu.addItem(annotate)
        annotateMenuItem = annotate

        let colorItem = NSMenuItem(title: "Annotation Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for c in AnnotationColor.allCases {
            let item = NSMenuItem(title: c.rawValue, action: #selector(chooseAnnotationColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.rawValue
            item.state = (c == annotationColor) ? .on : .off
            colorMenu.addItem(item)
        }
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        let undo = NSMenuItem(title: "Undo Last Stroke", action: #selector(undoStroke), keyEquivalent: "z")
        undo.target = self
        menu.addItem(undo)

        let clear = NSMenuItem(title: "Clear Annotations", action: #selector(clearAnnotations), keyEquivalent: "c")
        clear.keyEquivalentModifierMask = [.control, .option]   // display only — real binding is the Carbon hotkey
        clear.target = self
        menu.addItem(clear)
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

    /// Observes clicks in every other app (no permission required for
    /// mouse events) so Ripple/Laser can react to clicks made anywhere,
    /// even though our window itself is click-through in .pointer mode.
    private func installClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleGlobalClick(rightButton: event.type == .rightMouseDown)
        }
    }

    /// Registers ⌃⌥1-4 as system-wide effect-switching hotkeys via the
    /// Carbon Hot Key API. This is deliberately not NSEvent's global
    /// keyDown monitor: RegisterEventHotKey claims one specific combo with
    /// the OS and only that combo is ever delivered to us (consumed before
    /// any other app sees it), so — unlike watching every keystroke — it
    /// needs no Input Monitoring permission.
    private func installHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                       eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, userData in
            guard let eventRef = eventRef, let userData = userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                               nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async { delegate.hotKeyActions[id]?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        let signature: OSType = 0x474C5452   // 'GLTR'
        let modifiers = UInt32(controlKey | optionKey)   // ⌃⌥
        let bindings: [(id: UInt32, keyCode: UInt32, action: () -> Void)] = [
            (1, UInt32(kVK_ANSI_1), { [weak self] in self?.applyEffect(.glitter) }),
            (2, UInt32(kVK_ANSI_2), { [weak self] in self?.applyEffect(.ripple) }),
            (3, UInt32(kVK_ANSI_3), { [weak self] in self?.applyEffect(.spotlight) }),
            (4, UInt32(kVK_ANSI_4), { [weak self] in self?.applyEffect(.laser) }),
            (5, UInt32(kVK_ANSI_5), { [weak self] in self?.applyEffect(.none) }),
            (6, UInt32(kVK_ANSI_A), { [weak self] in self?.toggleAnnotateModeState() }),
            (7, UInt32(kVK_ANSI_C), { [weak self] in self?.clearAnnotations() }),
        ]

        for binding in bindings {
            hotKeyActions[binding.id] = binding.action
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: binding.id)
            RegisterEventHotKey(binding.keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            hotKeyRefs.append(ref)
        }
    }

    private func handleGlobalClick(rightButton: Bool) {
        guard isOn, mode == .pointer, effect == .ripple || effect == .laser else { return }
        let p = NSEvent.mouseLocation
        let origin = window.frame.origin
        let local = CGPoint(x: p.x - origin.x, y: p.y - origin.y)
        spawnRipple(at: local, rightButton: rightButton)
    }

    private func spawnRipple(at point: CGPoint, rightButton: Bool) {
        let startRadius: CGFloat = 6
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: point.x - startRadius, y: point.y - startRadius,
                             width: startRadius * 2, height: startRadius * 2)
        ring.path = CGPath(ellipseIn: CGRect(origin: .zero, size: ring.frame.size), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = (rightButton ? NSColor.systemBlue : pointerColor).cgColor
        ring.lineWidth = 3
        rippleContainer.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = Config.rippleMaxRadius / startRadius
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = CFTimeInterval(Config.rippleDuration)
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    private func tick() {
        guard isOn, mode == .pointer else { return }

        let p = NSEvent.mouseLocation
        let dx = p.x - lastPoint.x, dy = p.y - lastPoint.y
        let speed = (dx * dx + dy * dy).squareRoot()
        lastPoint = p

        // Screen coords → window coords
        let origin = window.frame.origin
        let local = CGPoint(x: p.x - origin.x, y: p.y - origin.y)

        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no implicit tweening on position

        switch effect {
        case .glitter:
            emitter.emitterPosition = local
            emitter.birthRate = speed < Config.minSpeed
                ? 0
                : Float(min(speed / Config.speedForFullRate, 1.6))

        case .laser:
            laserDot.path = CGPath(ellipseIn: CGRect(x: local.x - Config.laserDotRadius,
                                                       y: local.y - Config.laserDotRadius,
                                                       width: Config.laserDotRadius * 2,
                                                       height: Config.laserDotRadius * 2),
                                    transform: nil)

        case .spotlight:
            let full = CGPath(rect: CGRect(origin: .zero, size: window.frame.size), transform: nil)
            let hole = CGMutablePath()
            hole.addEllipse(in: CGRect(x: local.x - Config.spotlightRadius,
                                        y: local.y - Config.spotlightRadius,
                                        width: Config.spotlightRadius * 2,
                                        height: Config.spotlightRadius * 2))
            let combined = CGMutablePath()
            combined.addPath(full)
            combined.addPath(hole)
            spotlightLayer.path = combined

        case .ripple:
            break   // ripples spawn on click (see handleGlobalClick), nothing to do per-frame

        case .none:
            break   // plain system cursor, no per-frame drawing at all
        }

        CATransaction.commit()
    }

    // MARK: AnnotationDrawing

    func annotationBegin(at point: CGPoint) {
        guard mode == .annotate else { return }
        let path = CGMutablePath()
        path.move(to: point)
        let layer = CAShapeLayer()
        layer.strokeColor = annotationColor.color.cgColor
        layer.fillColor = nil
        layer.lineWidth = Config.annotationWidth
        layer.lineCap = .round
        layer.lineJoin = .round
        annotationLayer.addSublayer(layer)
        currentStroke = (path, layer)
    }

    func annotationDrag(to point: CGPoint) {
        guard let stroke = currentStroke else { return }
        stroke.path.addLine(to: point)
        stroke.layer.path = stroke.path
    }

    func annotationEnd() {
        guard let stroke = currentStroke else { return }
        strokeLayers.append(stroke.layer)
        currentStroke = nil
    }

    // MARK: Menu actions

    @objc private func toggleEffects(_ sender: NSMenuItem) {
        isOn.toggle()
        Prefs.isOn = isOn
        sender.state = isOn ? .on : .off

        // Annotate Mode already forces every pointer-effect layer hidden
        // independently of isOn -- don't fight that here.
        guard mode == .pointer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isOn {
            applyEffectVisibility()   // restore whichever effect is currently selected
        } else {
            // Hide everything, not just the glitter emitter -- previously
            // this left the laser dot or a spotlight cutout frozen on
            // screen, visible even with Cursor Effects switched off.
            emitter.birthRate = 0
            laserDot.isHidden = true
            spotlightLayer.isHidden = true
        }
        CATransaction.commit()
    }

    @objc private func chooseEffect(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let picked = PointerEffect(rawValue: raw) else { return }
        applyEffect(picked)
    }

    /// Shared by the Effect submenu and the ⌃⌥1-4 hotkeys.
    private func applyEffect(_ picked: PointerEffect) {
        effect = picked
        Prefs.effect = picked
        effectMenu?.items.forEach { $0.state = ($0.representedObject as? String == picked.rawValue) ? .on : .off }
        flashStatusItem(picked.rawValue)

        // Annotate Mode owns layer visibility while it's active (see
        // enterAnnotateMode/exitAnnotateMode) -- leave it alone here so a
        // hotkey pressed mid-drawing doesn't pop a pointer effect on top
        // of what you're annotating. exitAnnotateMode() re-applies
        // whatever effect is current once you're back in .pointer mode.
        guard mode == .pointer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyEffectVisibility()
        CATransaction.commit()
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

    /// Flips the overlay between click-through (.pointer) and
    /// click-capturing (.annotate). While Annotate Mode is on, ALL clicks
    /// go to drawing — none reach the app underneath — same tradeoff as
    /// Zoom's or Loom's built-in annotate tools. Toggle it off (from the
    /// menu, or press Escape) to resume normal interaction.
    @objc private func toggleAnnotateMode(_ sender: NSMenuItem) {
        toggleAnnotateModeState()
    }

    /// Shared by the menu item and the ⌃⌥A hotkey.
    private func toggleAnnotateModeState() {
        if mode == .pointer { enterAnnotateMode() } else { exitAnnotateMode() }
    }

    private func enterAnnotateMode() {
        mode = .annotate
        window.ignoresMouseEvents = false
        window.makeKey()   // lets Escape reach keyDown below, no permission needed
        annotateMenuItem?.state = .on
        flashStatusItem("Annotate On")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.birthRate = 0
        laserDot.isHidden = true
        spotlightLayer.isHidden = true
        CATransaction.commit()
    }

    /// The one guaranteed way back to normal interaction: reachable from
    /// the menu, and from Escape (OverlayWindow.onEscape) regardless of
    /// whatever the overlay's frame happens to cover.
    private func exitAnnotateMode() {
        guard mode == .annotate else { return }
        mode = .pointer
        window.ignoresMouseEvents = true
        annotateMenuItem?.state = .off
        flashStatusItem("Annotate Off")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyEffectVisibility()
        CATransaction.commit()
    }

    @objc private func chooseAnnotationColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let picked = AnnotationColor(rawValue: raw) else { return }
        annotationColor = picked
        Prefs.annotationColor = picked
        sender.menu?.items.forEach { $0.state = ($0 === sender) ? .on : .off }
    }

    @objc private func undoStroke() {
        guard let last = strokeLayers.popLast() else { return }
        last.removeFromSuperlayer()
    }

    @objc private func clearAnnotations() {
        strokeLayers.forEach { $0.removeFromSuperlayer() }
        strokeLayers.removeAll()
        flashStatusItem("Cleared")
    }

    @objc private func screensChanged() {
        let frame = deskFrame
        window.setFrame(frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = CGRect(origin: .zero, size: frame.size)
        rippleContainer.frame = CGRect(origin: .zero, size: frame.size)
        spotlightLayer.frame = CGRect(origin: .zero, size: frame.size)
        annotationLayer.frame = CGRect(origin: .zero, size: frame.size)
        CATransaction.commit()
    }
}

// MARK: - Launch

let app = NSApplication.shared
app.setActivationPolicy(.accessory)     // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
