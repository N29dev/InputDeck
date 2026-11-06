import AppKit
import CoreGraphics
import Foundation

// InputDeck: on-device keyboard state and trackpad visualizer.
// Key codes correspond to physical positions on a US ANSI keyboard.

private enum KeyCatalog {
    static let codes: [Int64: String] = [
        0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 11:"B",
        12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5",
        24:"=", 25:"9", 26:"7", 27:"-", 28:"8", 29:"0", 30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P",
        36:"Enter", 37:"L", 38:"J", 39:"'", 40:"K", 41:";", 42:"\\", 43:",", 44:"/", 45:"N", 46:"M", 47:".",
        48:"Tab", 49:"Space", 50:"`", 51:"Delete", 53:"Esc", 55:"Cmd", 56:"Shift", 57:"Caps", 58:"Option", 59:"Ctrl",
        60:"Shift", 61:"Option", 62:"Ctrl", 54:"Cmd", 122:"F1", 120:"F2", 99:"F3", 118:"F4", 96:"F5",
        97:"F6", 98:"F7", 100:"F8", 101:"F9", 109:"F10", 103:"F11", 111:"F12",
        123:"Left", 124:"Right", 125:"Down", 126:"Up"
    ]
    static let defaultKeys = ["Q","W","E","R","A","S","D","F","Shift","Ctrl","C","V","Space"]
    static let allowed = Set(codes.values)
    static let modifierNames: Set<String> = ["Shift", "Ctrl", "Option", "Cmd"]
    static let shortcuts = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map { String($0) } + (1...12).map { "F\($0)" }

    static func canonical(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = ["CONTROL":"Ctrl", "CTRL":"Ctrl", "SHIFT":"Shift", "ALT":"Option",
                       "OPTION":"Option", "COMMAND":"Cmd", "CMD":"Cmd", "RETURN":"Enter",
                       "ENTER":"Enter", "ESCAPE":"Esc", "ESC":"Esc", "BACKSPACE":"Delete",
                       "DELETE":"Delete", "SPACE":"Space", "CAPSLOCK":"Caps", "CAPS":"Caps",
                       "LEFT":"Left", "RIGHT":"Right", "UP":"Up", "DOWN":"Down", "TAB":"Tab"]
        let upper = trimmed.uppercased()
        let candidate = aliases[upper] ?? upper
        return allowed.contains(candidate) ? candidate : nil
    }

    static func keycode(for name: String) -> Int64? {
        codes.first(where: { $0.value == name })?.key
    }
}

private enum HotkeyModifiers: String, CaseIterable {
    case optionShift = "Option + Shift"
    case controlOption = "Control + Option"
    case commandShift = "Command + Shift"
    case commandOption = "Command + Option"
    case controlShift = "Control + Shift"
    case commandControl = "Command + Control"

    var flags: CGEventFlags {
        switch self {
        case .optionShift: return [.maskAlternate, .maskShift]
        case .controlOption: return [.maskControl, .maskAlternate]
        case .commandShift: return [.maskCommand, .maskShift]
        case .commandOption: return [.maskCommand, .maskAlternate]
        case .controlShift: return [.maskControl, .maskShift]
        case .commandControl: return [.maskCommand, .maskControl]
        }
    }
}

private struct Preferences {
    var tracked: [String]
    var hotkeyModifiers: HotkeyModifiers
    var hotkeyKey: String
    var trackpadVisible: Bool
    var opacity: CGFloat
    var isVisible: Bool
    var clickThrough: Bool

    static func load() -> Preferences {
        let defaults = UserDefaults.standard
        let stored = defaults.stringArray(forKey: "trackedKeys") ?? KeyCatalog.defaultKeys
        let valid = Array(stored.filter { KeyCatalog.allowed.contains($0) }.prefix(24))
        return Preferences(
            tracked: valid.isEmpty ? KeyCatalog.defaultKeys : valid,
            hotkeyModifiers: HotkeyModifiers(rawValue: defaults.string(forKey: "hotkeyModifiers") ?? "") ?? .optionShift,
            hotkeyKey: KeyCatalog.shortcuts.contains(defaults.string(forKey: "hotkeyKey") ?? "")
                ? defaults.string(forKey: "hotkeyKey")! : "K",
            trackpadVisible: defaults.object(forKey: "trackpadVisible") as? Bool ?? true,
            opacity: defaults.object(forKey: "overlayOpacity") == nil ? 0.88 : CGFloat(defaults.double(forKey: "overlayOpacity")),
            isVisible: defaults.object(forKey: "overlayVisible") as? Bool ?? true,
            clickThrough: defaults.object(forKey: "clickThrough") as? Bool ?? true
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(tracked, forKey: "trackedKeys")
        defaults.set(hotkeyModifiers.rawValue, forKey: "hotkeyModifiers")
        defaults.set(hotkeyKey, forKey: "hotkeyKey")
        defaults.set(trackpadVisible, forKey: "trackpadVisible")
        defaults.set(Double(opacity), forKey: "overlayOpacity")
        defaults.set(isVisible, forKey: "overlayVisible")
        defaults.set(clickThrough, forKey: "clickThrough")
    }
}

private let tapHandler: CGEventTapCallBack = { _, kind, event, context in
    if let context = context {
        Unmanaged<KeyCapture>.fromOpaque(context).takeUnretainedValue().consume(kind, event)
    }
    return Unmanaged.passUnretained(event)
}

final class KeyCapture {
    private(set) var pressed = Set<String>()
    var onChange: ((Set<String>) -> Void)?
    var onHotkey: (() -> Void)?
    private var selected = Set(KeyCatalog.defaultKeys)
    private var hotkeyCode: Int64 = 40
    private var hotkeyFlags: CGEventFlags = [.maskAlternate, .maskShift]
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    fileprivate func configure(_ settings: Preferences) {
        selected = Set(settings.tracked)
        hotkeyCode = KeyCatalog.keycode(for: settings.hotkeyKey) ?? 40
        hotkeyFlags = settings.hotkeyModifiers.flags
        pressed.formIntersection(selected)
        onChange?(pressed)
    }

    @discardableResult func start() -> Bool {
        if let tap = tap, CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                 | (CGEventMask(1) << CGEventType.keyUp.rawValue)
                 | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .listenOnly,
                                             eventsOfInterest: mask,
                                             callback: tapHandler,
                                             userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let createdSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), createdSource, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        source = createdSource
        return true
    }

    func consume(_ kind: CGEventType, _ event: CGEvent) {
        if kind == .tapDisabledByTimeout || kind == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if kind == .keyDown && code == hotkeyCode &&
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0 &&
           event.flags.intersection(modifierMask) == hotkeyFlags {
            onHotkey?()
        }
        let previous = pressed
        if kind == .flagsChanged {
            for (name, flag) in [("Shift", CGEventFlags.maskShift), ("Ctrl", .maskControl),
                                 ("Option", .maskAlternate), ("Cmd", .maskCommand)] {
                guard selected.contains(name) else { continue }
                if event.flags.contains(flag) { pressed.insert(name) }
                else { pressed.remove(name) }
            }
            if selected.contains("Caps"), code == 57 {
                if event.flags.contains(.maskAlphaShift) { pressed.insert("Caps") }
                else { pressed.remove("Caps") }
            }
        } else if let key = KeyCatalog.codes[code], selected.contains(key),
                  !KeyCatalog.modifierNames.contains(key) && key != "Caps" {
            if kind == .keyDown { pressed.insert(key) }
            else if kind == .keyUp { pressed.remove(key) }
        }
        if previous != pressed { onChange?(pressed) }
    }
}

final class OverlayView: NSView {
    var selected = KeyCatalog.defaultKeys { didSet { needsDisplay = true } }
    var pressed = Set<String>() { didSet { needsDisplay = true } }
    var fingers = [IDFinger]() { didSet { needsDisplay = true } }
    var trackpadAvailable = false { didSet { needsDisplay = true } }
    var showTrackpad = true { didSet { needsDisplay = true } }
    var opacity: CGFloat = 0.88 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    // The spacebar is displayed as a full-width row beneath the regular keys.
    // This keeps custom layouts compact while matching the physical key shape.
    static func keyRows(for keys: [String]) -> Int {
        let ordinaryCount = keys.filter { $0 != "Space" }.count
        return (ordinaryCount + 3) / 4 + (keys.contains("Space") ? 1 : 0)
    }
    static func panelHeight(for keys: [String]) -> CGFloat {
        max(224, CGFloat(52 + max(keyRows(for: keys), 1) * 43))
    }
    var panelSize: NSSize {
        NSSize(width: showTrackpad ? 503 : 266, height: Self.panelHeight(for: selected))
    }

    private func rectangle(_ rect: NSRect, fill: NSColor, radius: CGFloat = 8, outline: NSColor? = nil) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill(); path.fill()
        if let outline = outline { outline.setStroke(); path.lineWidth = 1; path.stroke() }
    }
    private func label(_ value: String, frame: NSRect, size: CGFloat = 12, color: NSColor = .white) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color, .paragraphStyle: style
        ]
        let text = NSAttributedString(string: value, attributes: attributes)
        let measured = text.size()
        text.draw(in: NSRect(x: frame.minX, y: frame.midY - measured.height / 2,
                             width: frame.width, height: measured.height + 3))
    }
    private func drawKey(_ key: String, in cell: NSRect) {
        let active = pressed.contains(key)
        rectangle(cell,
                  fill: active ? NSColor(srgbRed: 0.24, green: 0.48, blue: 0.93, alpha: 0.92)
                               : NSColor.white.withAlphaComponent(0.085),
                  outline: active ? NSColor(srgbRed: 0.49, green: 0.7, blue: 1, alpha: 0.95)
                                  : NSColor.white.withAlphaComponent(0.09))
        label(key.uppercased(), frame: cell,
              size: key == "Space" ? 11 : key.count > 4 ? 9 : key.count > 2 ? 10 : 13)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        rectangle(bounds.insetBy(dx: 2, dy: 2),
                  fill: NSColor(srgbRed: 0.045, green: 0.059, blue: 0.095, alpha: opacity),
                  radius: 17, outline: NSColor.white.withAlphaComponent(0.12))
        label("INPUTDECK", frame: NSRect(x: 17, y: 10, width: 235, height: 19),
              size: 10, color: NSColor.white.withAlphaComponent(0.65))

        let regularKeys = selected.filter { $0 != "Space" }
        for (index, key) in regularKeys.enumerated() {
            let row = index / 4, column = index % 4
            let cell = NSRect(x: 17 + CGFloat(column) * 60, y: 37 + CGFloat(row) * 43,
                              width: 55, height: 38)
            drawKey(key, in: cell)
        }
        if selected.contains("Space") {
            let rowsAboveSpace = (regularKeys.count + 3) / 4
            let spacebar = NSRect(x: 17, y: 37 + CGFloat(rowsAboveSpace) * 43,
                                  width: 235, height: 38)
            drawKey("Space", in: spacebar)
        }
        guard showTrackpad else { return }
        label("TRACKPAD", frame: NSRect(x: 273, y: 10, width: 213, height: 19),
              size: 10, color: NSColor.white.withAlphaComponent(0.65))
        let pad = NSRect(x: 273, y: 37, width: 213, height: bounds.height - 57)
        rectangle(pad, fill: NSColor(srgbRed: 0.10, green: 0.135, blue: 0.21, alpha: 0.80),
                  radius: 10, outline: NSColor.white.withAlphaComponent(0.21))
        if !trackpadAvailable {
            label("Trackpad unavailable", frame: pad, size: 11,
                  color: NSColor.white.withAlphaComponent(0.55))
        } else {
            for finger in fingers {
                let point = CGPoint(x: pad.minX + CGFloat(finger.x) * pad.width,
                                    y: pad.minY + (1 - CGFloat(finger.y)) * pad.height)
                NSColor(srgbRed: 0.32, green: 0.64, blue: 1, alpha: 0.18).setFill()
                NSBezierPath(ovalIn: NSRect(x: point.x - 16, y: point.y - 16,
                                            width: 32, height: 32)).fill()
                NSColor(srgbRed: 0.55, green: 0.79, blue: 1, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: point.x - 5.5, y: point.y - 5.5,
                                            width: 11, height: 11)).fill()
            }
        }
    }
}

final class AppController: NSObject, NSApplicationDelegate {
    private let capture = KeyCapture()
    private var preferences = Preferences.load()
    private var panel: NSPanel!
    private var view: OverlayView!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var settingsWindow: NSWindow?
    private var keysField: NSTextField!
    private var modifiersPopup: NSPopUpButton!
    private var shortcutPopup: NSPopUpButton!
    private var trackpadCheckbox: NSButton!
    private var opacitySlider: NSSlider!
    private var obsAvailable = false
    private var lastSent = ""
    private let obsURL = "http://127.0.0.1:8787/"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let size = NSSize(width: preferences.trackpadVisible ? 503 : 266,
                          height: OverlayView.panelHeight(for: preferences.tracked))
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        view = OverlayView(frame: NSRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        view.selected = preferences.tracked
        view.showTrackpad = preferences.trackpadVisible
        view.opacity = preferences.opacity
        panel.ignoresMouseEvents = preferences.clickThrough
        restorePanelPosition()
        if preferences.isVisible { panel.orderFrontRegardless() }
        NotificationCenter.default.addObserver(self, selector: #selector(overlayMoved(_:)),
                                               name: NSWindow.didMoveNotification, object: panel)

        let available = id_trackpad_start() != 0
        view.trackpadAvailable = available
        let html = Bundle.main.path(forResource: "overlay", ofType: "html") ?? ""
        obsAvailable = html.withCString { id_server_start($0, 8787) != 0 }
        capture.onChange = { [weak self] states in
            self?.view.pressed = states
            self?.publish()
        }
        capture.onHotkey = { [weak self] in self?.toggleVisibility() }
        capture.configure(preferences)
        _ = capture.start()
        setupMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60.0, repeats: true) {
            [weak self] _ in self?.refresh()
        }
        if let timer = timer { RunLoop.main.add(timer, forMode: .common) }
        publish()
    }

    private func refresh() {
        guard view.trackpadAvailable else { return }
        var buffer = [IDFinger](repeating: IDFinger(x: 0, y: 0, size: 0), count: 16)
        let count = buffer.withUnsafeMutableBufferPointer { points in
            Int(id_trackpad_copy(points.baseAddress, Int32(points.count)))
        }
        let next = Array(buffer.prefix(count))
        // Do not invalidate the overlay when nothing changed.
        if next.count != view.fingers.count || zip(next, view.fingers).contains(where: {
            $0.0.x != $0.1.x || $0.0.y != $0.1.y
        }) {
            view.fingers = next
            publish()
        }
    }

    private func publish() {
        guard obsAvailable else { return }
        let fingers: [[String: Double]] = view.fingers.map { finger in
            ["x": (Double(finger.x) * 1000).rounded() / 1000,
             "y": (Double(finger.y) * 1000).rounded() / 1000]
        }
        let state: [String: Any] = [
            "keys": capture.pressed.sorted(), "selected": preferences.tracked,
            "fingers": fingers, "trackpad": view.trackpadAvailable,
            "trackpadVisible": preferences.trackpadVisible,
            "opacity": Double(preferences.opacity)
        ]
        guard let bytes = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              let json = String(data: bytes, encoding: .utf8), json != lastSent else { return }
        lastSent = json
        json.withCString { id_server_publish($0) }
    }

    @discardableResult private func add(_ menu: NSMenu, _ name: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: name, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }
    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "InputDeck")
            if button.image == nil { button.title = "⌨︎" }
        }
        let menu = NSMenu()
        let title = NSMenuItem(title: "InputDeck · Keyboard + Trackpad", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        add(menu, "Show / hide overlay (global shortcut)", #selector(toggleVisibility))
        add(menu, "Preferences…", #selector(openPreferences))
        add(menu, "Toggle click-through (to drag)", #selector(toggleClickThrough))
        menu.addItem(.separator())
        add(menu, "Position: top left", #selector(topLeft))
        add(menu, "Position: top right", #selector(topRight))
        add(menu, "Position: bottom left", #selector(bottomLeft))
        add(menu, "Position: bottom right", #selector(bottomRight))
        menu.addItem(.separator())
        add(menu, "Open OBS preview in browser", #selector(openOBS))
        add(menu, "Retry keyboard permission", #selector(retryCapture))
        add(menu, "Open Input Monitoring settings", #selector(openSettings))
        menu.addItem(.separator())
        add(menu, "Quit InputDeck", #selector(quit))
        statusItem.menu = menu
    }

    private func restorePanelPosition() {
        let defaults = UserDefaults.standard
        guard !NSScreen.screens.isEmpty else { return }
        if defaults.object(forKey: "panelX") != nil, defaults.object(forKey: "panelY") != nil {
            let position = NSPoint(x: defaults.double(forKey: "panelX"),
                                   y: defaults.double(forKey: "panelY"))
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(position) }) {
                panel.setFrameOrigin(position)
                return
            }
        }
        positionPanel(corner: "topRight")
    }
    private func positionPanel(corner: String) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let r = screen.visibleFrame
        let margin: CGFloat = 20
        let x = corner.contains("Right") ? r.maxX - panel.frame.width - margin : r.minX + margin
        let y = corner.contains("top") ? r.maxY - panel.frame.height - margin : r.minY + margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        savePanelPosition()
    }
    private func savePanelPosition() {
        guard panel != nil else { return }
        UserDefaults.standard.set(Double(panel.frame.origin.x), forKey: "panelX")
        UserDefaults.standard.set(Double(panel.frame.origin.y), forKey: "panelY")
    }
    @objc private func overlayMoved(_ notification: Notification) { savePanelPosition() }
    @objc private func toggleVisibility() {
        preferences.isVisible.toggle()
        preferences.save()
        if preferences.isVisible { panel.orderFrontRegardless() }
        else { panel.orderOut(nil) }
    }
    @objc private func toggleClickThrough() {
        preferences.clickThrough.toggle()
        preferences.save()
        panel.ignoresMouseEvents = preferences.clickThrough
    }
    @objc private func topLeft() { positionPanel(corner: "topLeft") }
    @objc private func topRight() { positionPanel(corner: "topRight") }
    @objc private func bottomLeft() { positionPanel(corner: "bottomLeft") }
    @objc private func bottomRight() { positionPanel(corner: "bottomRight") }
    @objc private func openOBS() { if let url = URL(string: obsURL) { NSWorkspace.shared.open(url) } }
    @objc private func retryCapture() { _ = capture.start() }
    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func label(_ text: String, frame: NSRect, font: CGFloat = 12) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = frame
        field.font = .systemFont(ofSize: font)
        field.textColor = .secondaryLabelColor
        return field
    }
    @objc private func openPreferences() {
        if let window = settingsWindow { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 380),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "InputDeck Preferences"
        window.center()
        window.isReleasedWhenClosed = false
        guard let content = window.contentView else { return }
        content.addSubview(label("Tracked keys (1–24, comma-separated)", frame: NSRect(x: 24, y: 326, width: 470, height: 21), font: 13))
        keysField = NSTextField(frame: NSRect(x: 24, y: 288, width: 482, height: 29))
        keysField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        keysField.stringValue = preferences.tracked.joined(separator: ", ")
        content.addSubview(keysField)
        content.addSubview(label("Uses physical US key positions. Examples: W, A, Space, Shift, Option, Tab, F1, Left",
                                 frame: NSRect(x: 24, y: 263, width: 480, height: 19), font: 10))
        content.addSubview(label("Global show/hide shortcut", frame: NSRect(x: 24, y: 226, width: 480, height: 20), font: 13))
        modifiersPopup = NSPopUpButton(frame: NSRect(x: 24, y: 192, width: 238, height: 26), pullsDown: false)
        modifiersPopup.addItems(withTitles: HotkeyModifiers.allCases.map(\.rawValue))
        modifiersPopup.selectItem(withTitle: preferences.hotkeyModifiers.rawValue)
        content.addSubview(modifiersPopup)
        shortcutPopup = NSPopUpButton(frame: NSRect(x: 274, y: 192, width: 100, height: 26), pullsDown: false)
        shortcutPopup.addItems(withTitles: KeyCatalog.shortcuts)
        shortcutPopup.selectItem(withTitle: preferences.hotkeyKey)
        content.addSubview(shortcutPopup)
        trackpadCheckbox = NSButton(checkboxWithTitle: "Show trackpad", target: nil, action: nil)
        trackpadCheckbox.frame = NSRect(x: 24, y: 144, width: 240, height: 23)
        trackpadCheckbox.state = preferences.trackpadVisible ? .on : .off
        content.addSubview(trackpadCheckbox)
        content.addSubview(label("Background opacity", frame: NSRect(x: 24, y: 111, width: 200, height: 19)))
        opacitySlider = NSSlider(value: Double(preferences.opacity), minValue: 0.4, maxValue: 1,
                                 target: nil, action: nil)
        opacitySlider.frame = NSRect(x: 206, y: 109, width: 169, height: 24)
        content.addSubview(opacitySlider)
        content.addSubview(label("Global shortcut requires Input Monitoring permission.",
                                 frame: NSRect(x: 24, y: 75, width: 470, height: 18), font: 11))
        let restore = NSButton(title: "Defaults", target: self, action: #selector(restoreDefaults))
        restore.frame = NSRect(x: 24, y: 22, width: 98, height: 30)
        content.addSubview(restore)
        let save = NSButton(title: "Save Settings", target: self, action: #selector(savePreferences))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded
        save.frame = NSRect(x: 356, y: 22, width: 150, height: 30)
        content.addSubview(save)
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func restoreDefaults() {
        keysField.stringValue = KeyCatalog.defaultKeys.joined(separator: ", ")
        modifiersPopup.selectItem(withTitle: HotkeyModifiers.optionShift.rawValue)
        shortcutPopup.selectItem(withTitle: "K")
        trackpadCheckbox.state = .on
        opacitySlider.doubleValue = 0.88
    }
    @objc private func savePreferences() {
        let tokens = keysField.stringValue.split(separator: ",", omittingEmptySubsequences: false)
        var chosen: [String] = []
        var invalid: [String] = []
        for token in tokens {
            if let name = KeyCatalog.canonical(String(token)) {
                if !chosen.contains(name) { chosen.append(name) }
            } else { invalid.append(String(token).trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        if !invalid.isEmpty || chosen.isEmpty || chosen.count > 24 {
            let alert = NSAlert()
            alert.messageText = "Invalid tracked keys"
            alert.informativeText = "Use 1–24 supported keys separated by commas. Unrecognized: \(invalid.joined(separator: ", "))."
            alert.runModal()
            return
        }
        preferences.tracked = chosen
        preferences.hotkeyModifiers = HotkeyModifiers(rawValue: modifiersPopup.titleOfSelectedItem ?? "") ?? .optionShift
        preferences.hotkeyKey = shortcutPopup.titleOfSelectedItem ?? "K"
        preferences.trackpadVisible = trackpadCheckbox.state == .on
        preferences.opacity = CGFloat(opacitySlider.doubleValue)
        preferences.save()
        capture.configure(preferences)
        view.selected = preferences.tracked
        view.showTrackpad = preferences.trackpadVisible
        view.opacity = preferences.opacity
        let oldOrigin = panel.frame.origin
        let newSize = view.panelSize
        panel.setContentSize(newSize)
        panel.setFrameOrigin(oldOrigin)
        savePanelPosition()
        publish()
        settingsWindow?.orderOut(nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        id_server_stop()
        id_trackpad_stop()
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
