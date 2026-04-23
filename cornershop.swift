import Cocoa
import CoreGraphics
import Carbon

// MARK: - Data

struct WindowInfo {
    let ownerName: String
    let windowName: String
    let pid: pid_t
    let windowID: CGWindowID
    let frame: CGRect   // CG flipped coords (top-left origin)
    let layer: Int
}

// MARK: - Window collection

func collectWindows(screenIndex: Int) -> [WindowInfo] {
    let screens = NSScreen.screens
    guard screenIndex >= 0 && screenIndex < screens.count else { return [] }

    guard let screenNumber = screens[screenIndex].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
        print("Error: could not get display ID for screen \(screenIndex)")
        return []
    }
    let screenCGBounds = CGDisplayBounds(screenNumber)

    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        print("Error: failed to get window list")
        return []
    }

    var windows: [WindowInfo] = []
    for raw in rawList {
        guard
            let boundsDict = raw[kCGWindowBounds as String] as? [String: CGFloat],
            let x = boundsDict["X"], let y = boundsDict["Y"],
            let width = boundsDict["Width"], let height = boundsDict["Height"],
            let pid = raw[kCGWindowOwnerPID as String] as? pid_t,
            let wid = raw[kCGWindowNumber as String] as? CGWindowID
        else { continue }

        let cgFrame = CGRect(x: x, y: y, width: width, height: height)
        let layer = raw[kCGWindowLayer as String] as? Int ?? -1
        guard layer == 0, screenCGBounds.intersects(cgFrame) else { continue }

        windows.append(WindowInfo(
            ownerName: raw[kCGWindowOwnerName as String] as? String ?? "Unknown",
            windowName: raw[kCGWindowName as String] as? String ?? "",
            pid: pid,
            windowID: wid,
            frame: cgFrame,
            layer: layer
        ))
    }
    return windows
}

// MARK: - AX matching

// Returns true if the AX window's current position and size match the CG frame (within tolerance).
// kAXPositionAttribute uses the same top-left-origin CG coordinate space, so no conversion needed.
func axMatchesCGFrame(_ axWindow: AXUIElement, cgFrame: CGRect, tolerance: CGFloat = 5) -> Bool {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let posRef, let sizeRef
    else { return false }

    var axPos = CGPoint.zero
    var axSize = CGSize.zero
    AXValueGetValue(posRef as! AXValue, .cgPoint, &axPos)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &axSize)

    return abs(axPos.x - cgFrame.origin.x) < tolerance &&
           abs(axPos.y - cgFrame.origin.y) < tolerance &&
           abs(axSize.width - cgFrame.width) < tolerance &&
           abs(axSize.height - cgFrame.height) < tolerance
}

// Finds the AX window element that corresponds to a given CGWindow entry.
// Tries the window's own PID first, then falls back to any other running process
// with the same app name — needed for Chrome's multi-process model where DevTools
// windows are owned by a helper PID that has no accessible AX windows of its own.
// cache avoids redundant kAXWindowsAttribute IPC calls when the same PID appears
// multiple times (e.g. several Chrome windows on screen).
func findAXWindow(for w: WindowInfo,
                  cache: inout [pid_t: [AXUIElement]],
                  runningApps: [NSRunningApplication]) -> AXUIElement? {
    func axWindows(pid: pid_t) -> [AXUIElement] {
        if let cached = cache[pid] { return cached }
        let appRef = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let result: [AXUIElement]
        if AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value) == .success,
           let list = value as? [AXUIElement] {
            result = list
        } else {
            result = []
        }
        cache[pid] = result
        return result
    }

    func firstMatch(pid: pid_t) -> AXUIElement? {
        axWindows(pid: pid).first { axWindow in
            var minVal: CFTypeRef?
            let minimised = AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minVal) == .success
                && (minVal as? Bool == true)
            return !minimised && axMatchesCGFrame(axWindow, cgFrame: w.frame)
        }
    }

    if let match = firstMatch(pid: w.pid) { return match }

    for app in runningApps where app.localizedName == w.ownerName && app.processIdentifier != w.pid {
        if let match = firstMatch(pid: app.processIdentifier) { return match }
    }

    return nil
}

// MARK: - Arrange

func rearrangeWindows(screenIndex: Int, pixelGap: Int = 30) {
    let screens = NSScreen.screens
    let screen = screens[screenIndex]
    guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
        print("Error: could not get display ID for screen \(screenIndex)")
        return
    }
    let cgBounds = CGDisplayBounds(screenNumber)
    let visibleFrame = screen.visibleFrame
    let maxUsableWidth = visibleFrame.width
    let menuBarHeight = NSStatusBar.system.thickness
    let vfMenuBarHeight = screen.frame.maxY - visibleFrame.maxY
    let dockHeight = max(0, screen.frame.height - visibleFrame.height - vfMenuBarHeight)
    let maxUsableHeight = cgBounds.height - menuBarHeight - dockHeight

    let windows = collectWindows(screenIndex: screenIndex)
    print("Arranging \(windows.count) window(s) on screen \(screenIndex)...")

    var counter = 0
    var counterWidth = windows.count
    var axCache: [pid_t: [AXUIElement]] = [:]
    let runningApps = NSWorkspace.shared.runningApplications

    for w in windows {
        guard let axWindow = findAXWindow(for: w, cache: &axCache, runningApps: runningApps) else {
            print("Skipped (no AX match): \(w.ownerName)\(w.windowName.isEmpty ? "" : " — \(w.windowName)")")
            counterWidth -= 1
            continue
        }

        let newWidth = Int(maxUsableWidth) - ((counterWidth - 1) * pixelGap)
        let newHeight = Int(maxUsableHeight) - (counter * pixelGap)
        let origin = CGPoint(x: cgBounds.minX, y: cgBounds.minY + menuBarHeight + CGFloat(counter * pixelGap))

        counter += 1
        counterWidth -= 1

        var pos = origin
        if let posValue = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
        }
        var size = CGSize(width: newWidth, height: newHeight)
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
        }
        print("Moved + Resized: \(w.ownerName) \(newWidth)x\(newHeight)")
    }
    print("Done.")
}

// MARK: - Hotkey

// Must be a free C-compatible function — Swift closures that capture context cannot
// be passed as EventHandlerUPP. Self is threaded through via userData instead.
private func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let ptr = userData else { return noErr }
    Unmanaged<AppController>.fromOpaque(ptr).takeUnretainedValue().arrangeScreenUnderMouse()
    return noErr
}

private func fourCharCode(_ s: String) -> FourCharCode {
    s.unicodeScalars.reduce(0) { ($0 << 8) + FourCharCode($1.value) }
}

// MARK: - Slider menu item

class SliderMenuItemView: NSView {
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    var onChange: ((Int) -> Void)?

    init(value: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 38))

        let label = NSTextField(labelWithString: "Gap")
        label.frame = NSRect(x: 14, y: 10, width: 28, height: 18)
        label.font = .menuFont(ofSize: 0)

        slider.frame = NSRect(x: 46, y: 9, width: 118, height: 20)
        slider.minValue = 0
        slider.maxValue = 100
        slider.integerValue = value
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true

        valueLabel.frame = NSRect(x: 168, y: 10, width: 44, height: 18)
        valueLabel.alignment = .right
        valueLabel.font = .menuFont(ofSize: 0)
        updateLabel()

        addSubview(label)
        addSubview(slider)
        addSubview(valueLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func sliderChanged() {
        updateLabel()
        onChange?(slider.integerValue)
    }

    private func updateLabel() {
        valueLabel.stringValue = "\(slider.integerValue)px"
    }
}

// MARK: - App controller

class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var pixelGap = 30

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        registerHotKey()
        promptAccessibilityIfNeeded()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                           accessibilityDescription: "Cornershop")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuild on every open so the screen list is always current
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        for (i, screen) in NSScreen.screens.enumerated() {
            let item = NSMenuItem(
                title: "Arrange \(screen.localizedName)",
                action: #selector(arrangeMenuScreen(_:)),
                keyEquivalent: ""
            )
            item.tag = i
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let sliderView = SliderMenuItemView(value: pixelGap)
        sliderView.onChange = { [weak self] newValue in self?.pixelGap = newValue }
        let sliderItem = NSMenuItem()
        sliderItem.view = sliderView
        menu.addItem(sliderItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Cornershop",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    @objc private func arrangeMenuScreen(_ sender: NSMenuItem) {
        guard AXIsProcessTrusted() else { promptAccessibilityIfNeeded(); return }
        rearrangeWindows(screenIndex: sender.tag, pixelGap: pixelGap)
    }

    func arrangeScreenUnderMouse() {
        guard AXIsProcessTrusted() else { promptAccessibilityIfNeeded(); return }
        let mouse = NSEvent.mouseLocation
        let index = NSScreen.screens.firstIndex(where: { $0.frame.contains(mouse) }) ?? 0
        rearrangeWindows(screenIndex: index, pixelGap: pixelGap)
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType, selfPtr, nil)

        let hkID = EventHotKeyID(signature: fourCharCode("CORN"), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            UInt32(cmdKey | controlKey),
            hkID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &hotKeyRef
        )
    }

    private func promptAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "Cornershop needs Accessibility access to move and resize windows.\n\nGo to System Settings → Privacy & Security → Accessibility."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()
