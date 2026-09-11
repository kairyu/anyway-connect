import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var state: VPNState = .disconnected
    var busy = false
    var pollTimer: Timer?
    var settingsWC: SettingsWindowController?

    var lastEndpointKey: String?
    /// Endpoint a connect is currently heading for, so the menu can mark *which* one
    /// is in progress. `busy` cannot answer that: it is also true while disconnecting,
    /// when nothing is being connected to at all.
    var connectingKey: String?
    var reconnectAttempts = 0
    var userInitiatedDisconnect = false
    private var busyWatchdog: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Enforced here, not in main.swift, because a redundant launch now asks the user
        // what to do — and NSAlert cannot present until AppKit has finished launching.
        // A duplicate does a little needless AppKit setup before exiting, which is a
        // cheap price for a dialog that actually appears.
        if !SingleInstance.acquire() {
            switch SingleInstance.askUserWhatToDo() {
            case .showSettings:
                SingleInstance.handOffToRunningInstance()
                exit(0)
            case .cancel:
                exit(0)
            case .restart:
                guard SingleInstance.replaceRunningInstance() else {
                    SingleInstance.reportRestartFailure()
                    exit(1)
                }
                // Took the lock from the old copy; carry on and set up normally.
            }
        }

        // Set before anything can show an alert or a Dock icon, since all of them read
        // this. Without it the bundle has no icon and macOS supplies its generic one.
        NSApp.applicationIconImage = AppIcon.standard

        resolveWrapperPaths()
        discardOffScreenStatusItemPosition()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The whole UI is this one icon: if it never becomes visible the app is running
        // and unreachable, with no way back short of `killall`. So say enough in the
        // log to tell "no image" apart from "placed off-screen" without guesswork.
        statusItem.isVisible = true
        refresh()
        // After refresh(), not before: refresh() is what installs the image, so logging
        // any earlier always reports image=false and says nothing.
        // Checked once, late. The frame is zero-height at launch and macOS can take a
        // couple of seconds to assign a slot — measured landing at ~3s in a test — so an
        // earlier look reports a problem that isn't there yet.
        schedulePlacementCheck(in: 6, attempt: 1)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.refresh() }

        // A second launch hands off to us rather than starting a rival instance.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showSettingsOnRelaunch),
            name: SingleInstance.showSettingsNotification, object: nil)

        // The usual way in when the icon is missing. Double-clicking the app does NOT
        // start a second process — macOS sends this event to the copy already running —
        // so without a handler here a re-launch does nothing whatsoever, which is exactly
        // what it appeared to do. The obvious hook, applicationShouldHandleReopen, is
        // never called for an accessory app; only the raw event arrives. Installing this
        // replaces AppKit's own handler, which is fine: all it would have done is call
        // that uncalled delegate method and unhide windows this app does not have.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleReopenEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication))
    }

    /// Guards against stacking one alert per impatient double-click.
    private var reopenPromptShowing = false

    /// Answer a re-launch — the only route back in once the icon is not visible.
    ///
    /// Deferred to the next turn of the main loop rather than run inline: an Apple Event
    /// handler must return promptly, and a modal alert holds the main thread for as long
    /// as the user takes to read it, which would leave the launch waiting on a reply.
    @objc private func handleReopenEvent(_ event: NSAppleEventDescriptor,
                                         withReply reply: NSAppleEventDescriptor) {
        // In Dock fallback the app is plainly visible and clicking its icon sends this
        // event, so an "already running" dialog would be both obvious and in the way.
        // Go straight to Settings, which is what clicking a Dock icon should do.
        if dockFallbackEngaged {
            DispatchQueue.main.async { [weak self] in self?.openSettings() }
            return
        }
        guard !reopenPromptShowing else { return }
        reopenPromptShowing = true
        DispatchQueue.main.async { [weak self] in
            defer { self?.reopenPromptShowing = false }
            switch SingleInstance.askWhatToDoOnReopen() {
            case .showSettings: self?.openSettings()
            case .quit:         NSApp.terminate(nil)
            case .cancel:       break
            }
        }
    }

    /// Drop a remembered menu-bar position that no longer lands on any display.
    ///
    /// macOS saves where a status item was dragged to under "NSStatusItem Preferred
    /// Position …". That coordinate is in the whole-desktop space, so unplugging a
    /// display can leave it pointing at empty air — and the item is then placed where
    /// nobody can see it, with the app apparently running but unreachable. Observed
    /// exactly that: a saved position of 5596 on a desktop that only reached ~3331,
    /// after a third monitor was removed.
    ///
    /// The key is Apple's, not ours, so treat it as advisory: only ever delete it, and
    /// only when it is clearly outside every screen. Losing a remembered position
    /// costs the user nothing — macOS just picks a spot again.
    private func discardOffScreenStatusItemPosition() {
        let span = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        guard !span.isNull else { return }
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation()
        where key.hasPrefix("NSStatusItem Preferred Position") {
            guard let x = (value as? NSNumber)?.doubleValue else { continue }
            // A little slack: the saved value is the item's leading edge, and the menu
            // bar's usable width is slightly less than the screen union.
            if x < span.minX - 64 || x > span.maxX + 64 {
                NSLog("AnywayConnect: discarding stale menu-bar position \(x) for '\(key)' "
                    + "— outside the current display span \(span.minX)...\(span.maxX)")
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Why the icon may be unusable. Kept as distinct cases because "no image" is our
    /// bug and "placed off-screen" is macOS's decision, and the two were once
    /// indistinguishable in the log — which cost an hour of looking in the wrong place.
    private enum Placement {
        case ok
        case noButton
        case noImage
        case notYetLaidOut
        case offScreen(NSRect)
    }

    private func statusItemPlacement() -> Placement {
        guard let button = statusItem.button else { return .noButton }
        guard button.image != nil else { return .noImage }
        // A zero-height frame only means layout has not happened yet, which is normal
        // during launch — not something to conclude anything from.
        guard let frame = button.window?.frame, frame.height > 0 else { return .notYetLaidOut }
        if NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) { return .ok }
        return .offScreen(frame)
    }

    private func schedulePlacementCheck(in seconds: TimeInterval, attempt: Int) {
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.verifyStatusItemPlacement(attempt: attempt)
        }
    }

    /// Make sure the one piece of UI this app has is actually reachable, and do something
    /// about it when it is not.
    ///
    /// Ordered cheapest-first: ask again if layout is simply not finished, then tear the
    /// item down and build it again (which asks macOS for a slot afresh and costs
    /// nothing), and only then fall back to a Dock icon. Recreating is worth a try
    /// because the placement is decided once, when the item is created.
    ///
    /// The off-screen case is worth all this because it is real and external: observed
    /// parked at {0, -22}, the window's top edge exactly at the bottom of the primary
    /// display, while the item reported its image set and isVisible true throughout — so
    /// nothing in the app's own state hinted at it. Ruled out, each by test: the icon
    /// itself (it renders correctly), isVisible, item creation, the delegate lifecycle,
    /// disk space, the saved "NSStatusItem Preferred Position" (absent, valid and deleted
    /// all behave alike), menu bar capacity, Control Center's state, and the launch
    /// method. A standalone harness places items correctly on this machine in every one
    /// of those configurations, and the state appears to be keyed to the bundle
    /// identifier. No cause is claimed here: an earlier version blamed a full menu bar,
    /// which later evidence disproved.
    private func verifyStatusItemPlacement(attempt: Int) {
        switch statusItemPlacement() {
        case .ok:
            return

        case .noButton:
            NSLog("AnywayConnect: status item has NO button — the icon cannot appear")
            engageDockFallback(reason: "macOS did not give the menu bar item a button.")

        case .noImage:
            NSLog("AnywayConnect: status item has no image — it will be zero-width")
            engageDockFallback(reason: "The menu bar icon has no image, so it has no width.")

        case .notYetLaidOut:
            // Give layout more time rather than treating "not yet" as "never".
            guard attempt < 4 else { return }
            schedulePlacementCheck(in: 4, attempt: attempt + 1)

        case .offScreen(let frame):
            if attempt == 1 {
                NSLog("AnywayConnect: menu bar icon parked at \(NSStringFromRect(frame)) "
                    + "— discarding any saved position and recreating the item")
                reinstallStatusItem()
                schedulePlacementCheck(in: 5, attempt: 2)
                return
            }
            NSLog("AnywayConnect: the menu bar icon was not placed on any screen "
                + "(\(NSStringFromRect(frame))). macOS decides this, and the cause is not "
                + "known: it has been reproduced with a free disk, with and without a saved "
                + "position, after freeing menu bar space, and after restarting Control "
                + "Center. Falling back to a Dock icon so the app stays usable.")
            engageDockFallback(reason: "macOS placed the menu bar icon off-screen, "
                + "at \(Int(frame.origin.x)), \(Int(frame.origin.y)).")
        }
    }

    /// Rebuild the status item from scratch, first dropping any remembered position.
    private func reinstallStatusItem() {
        NSStatusBar.system.removeStatusItem(statusItem)
        discardOffScreenStatusItemPosition()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        // refresh() is what installs the image and the menu, so the new item is only
        // complete after it runs.
        refresh()
    }

    private var dockFallbackEngaged = false

    /// Become an ordinary app so the user can still work when the icon is missing.
    ///
    /// This exists because the menu bar icon is the *entire* interface: Settings has no
    /// connect or disconnect controls, deliberately, since the menu was always meant to
    /// carry them. With the icon unplaced the tunnel could not be started, stopped, or
    /// even the app quit — a running process with no way in. A Dock icon restores all of
    /// it: the same menu appears on right-click, and a menu bar of our own gives ⌘Q back.
    ///
    /// A last resort, not a preference: the app is an accessory by design, and this
    /// changes its whole character, so it only ever happens after a placement retry has
    /// already failed.
    private func engageDockFallback(reason: String) {
        guard !dockFallbackEngaged else { return }
        dockFallbackEngaged = true
        NSLog("AnywayConnect: engaging Dock fallback — \(reason)")

        NSApp.setActivationPolicy(.regular)
        installFallbackMainMenu()

        // Told once, plainly. Without this the app silently changes shape and the user is
        // left to work out why a menu bar app is suddenly in the Dock.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "AnywayConnect is in the Dock"
        alert.informativeText = """
            \(reason)

            So that you can still connect and disconnect, AnywayConnect is showing a Dock \
            icon instead. Click it — or use the AnywayConnect menu — to reach everything \
            the menu bar icon would have offered.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// A menu bar of our own, holding the same menu as the status item.
    private func installFallbackMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        // AppKit titles the first menu from the bundle name, so this needs no title of
        // its own. Reusing buildMenu() means the Dock route can never drift from the
        // menu bar route.
        appItem.submenu = buildMenu()
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    /// The same menu again, for right-click (or press-and-hold) on the Dock icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        buildMenu()
    }

    @objc func showSettingsOnRelaunch() {
        openSettings()
    }

    /// Flip the menu-bar name preference from the menu itself.
    ///
    /// Writes through ConfigStore rather than holding local state, so this and the
    /// checkbox in Settings are two views of one value and cannot disagree.
    @objc func toggleEndpointName() {
        ConfigStore.shared.update { c in
            c.general.menubar.showEndpointName.toggle()
        }
        updateButton()
        rebuildMenu()
    }

    func resolveWrapperPaths() {
        let fm = FileManager.default
        func find(_ name: String) -> String {
            if let r = Bundle.main.resourcePath {
                let p = (r as NSString).appendingPathComponent(name)
                if fm.fileExists(atPath: p) { return p }
            }
            return (NSHomeDirectory() as NSString).appendingPathComponent("anyway-connect/scripts/\(name)")
        }
        let b = ConfigStore.shared.config.general.externalBrowser
        VPNRunner.shared.browserWrapperPath = b.isEmpty ? find("open-browser.sh") : b
    }

    // MARK: - Icons

    enum IconState { case disconnected, connecting, connected }
    func stateForIcon() -> IconState {
        if busy { return .connecting }
        if case .connected = state { return .connected }
        return .disconnected
    }

    // Every state is the same globe with a badge in the same corner, so only the
    // badge changes and the item never shifts. Three things were wrong before:
    //
    //  - The lock was drawn overlapping the globe's own strokes, so two outline
    //    glyphs interleaved and neither read clearly. It is now knocked out of the
    //    globe, which is how the system's own badged symbols stay legible.
    //  - "globe.badge.chevron.backward" puts its badge bottom-LEFT, so connecting
    //    and connected badged opposite corners.
    //  - The canvases differed (16x16 vs 18x16), moving the icon between states.
    // Geometry is chosen so every major edge lands on a whole point, which is what
    // keeps the shapes crisp at 1x. The trap is parity: an even diameter needs an
    // INTEGER centre and an odd one needs a half-integer centre. The previous layout
    // paired a 12pt disc with a 15.5 centre, so it spanned 9.5...21.5 and every edge
    // fell mid-pixel. Now the disc is 12pt about x=15, spanning 9...21.
    //
    // The status button is 22pt tall and its imageScaling is .scaleNone, so an image
    // is never scaled down — up to 22pt draws in full and beyond that clips. 19pt
    // leaves 1.5pt of margin top and bottom.
    private static var warnedAboutMissingIcon = false

    private static let iconCanvas = NSSize(width: 21, height: 19)

    /// Height AND width of the globe's visible ink. Not a box to squeeze it into: the
    /// old code drew globe@15 (15pt of ink in a ~17pt padded box) into a 15pt rect,
    /// scaling it down to 12.50x13.25 of actual ink. Drawing at natural size recovers
    /// the full 15pt. 16 is deliberately avoided — SF Symbols' optical variant makes
    /// the globe's ink 16.88 wide there, visibly non-square.
    private static let globeInk: CGFloat = 15
    /// Bottom-left corner of that ink. Ink therefore spans 0...15 and 2...17.
    ///
    /// y=2 rather than 4 so the globe is centred in the canvas (2 + 15/2 == 19/2), and
    /// therefore centred in the menu bar: the status item centres the whole image, so
    /// the 2pt of empty canvas above the globe is what balances the badge hanging below
    /// it. At y=4 the globe sat 2pt high. Keeping y=4 *and* centring would need a 23pt
    /// canvas, which the 22pt button clips — so the badge necessarily overlaps the globe
    /// a little more. That costs only ~2% of the globe's ink, because the badge covers
    /// the globe's edge where there is barely any.
    private static let globeInkOrigin = NSPoint(x: 0, y: 2)

    // Diameter of the badge's visible disc, not of a bounding box — see the note on
    // symbol padding in globeIcon(badge:describing:).
    private static let badgeDiameter: CGFloat = 12
    private static let badgeCenter = NSPoint(x: 15, y: 6)
    private static let badgeRing: CGFloat = 1.0
    private static let badgeDisc = NSRect(x: badgeCenter.x - badgeDiameter / 2,
                                         y: badgeCenter.y - badgeDiameter / 2,
                                         width: badgeDiameter, height: badgeDiameter)

    /// Fraction of the disc's height given to the knocked-out padlock.
    ///
    /// `lock.circle.fill` hands its lock only 51% — a 6.1pt mark 4.25pt wide inside a
    /// 12pt disc, which is *narrower* than the 7.25pt ellipsis it has to be told apart
    /// from, so the lock was the weakest mark in the set. Growing the disc barely helps
    /// (a 14pt disc still yields only a 7.25pt lock) and eats more of the globe, so the
    /// connected badge composes its own disc instead and sizes the lock directly.
    ///
    /// Measured ceiling: the lock's top corners, not its flat top, set the limit. At
    /// 0.80 they reach 5.50pt of the 6pt radius, leaving 0.50pt of ring that visually
    /// merges with the lock even though it never strictly breaks it. 0.72 leaves
    /// 0.96pt — roughly two device pixels at 2x — and stays legible at 1x.
    private static let lockShareOfBadge: CGFloat = 0.72

    /// The globe, plus the measured bounds of its visible ink, so it can be placed and
    /// sized by ink rather than by its padded box. Cached: the icon is rebuilt on every
    /// status poll and measuring means rendering.
    private static let globeGlyph: (image: NSImage, ink: NSRect)? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: globeInk, weight: .regular)
        guard let img = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg), let ink = inkBounds(of: img) else { return nil }
        return (img, ink)
    }()

    /// `lock.fill` rendered large, plus the measured bounds of its visible ink.
    ///
    /// Its padding is asymmetric (at 8pt: 1.12pt left but 1.50pt right), so centring
    /// the reported box would sit the lock off-centre. Measuring instead of hardcoding
    /// ratios means an SF Symbol metrics change can't silently shift the badge. Done
    /// once and cached, since the icon is rebuilt on every status poll.
    private static let lockGlyph: (image: NSImage, ink: NSRect)? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        guard let img = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Connected")?
            .withSymbolConfiguration(cfg), let ink = inkBounds(of: img) else { return nil }
        return (img, ink)
    }()

    /// Bounding box of an image's non-transparent pixels, in points. Shared with the app
    /// icon, which places its glyphs by the same measurement — see `AppIcon`.
    private static func inkBounds(of image: NSImage, scale: CGFloat = 16) -> NSRect? {
        AppIcon.inkBounds(of: image, scale: scale)
    }

    private enum Badge {
        case none
        /// A stock ".circle.fill" symbol, drawn as it ships.
        case symbol(String)
        /// Disc composed here so the padlock can be larger than the stock symbol's.
        case lock
    }

    func iconImage() -> NSImage? {
        switch stateForIcon() {
        case .disconnected: return globeIcon(badge: .none, describing: "Disconnected")
        case .connecting:   return globeIcon(badge: .symbol("ellipsis.circle.fill"),
                                             describing: "Connecting")
        case .connected:    return globeIcon(badge: .lock, describing: "Connected")
        }
    }

    private func globeIcon(badge: Badge, describing: String) -> NSImage? {
        guard let globe = Self.globeGlyph else { return nil }
        // Scale by measured ink so globeInk is real ink, then offset so the ink — not
        // the padded box — starts at globeInkOrigin.
        let gk = Self.globeInk / globe.ink.height
        let gSize = globe.image.size
        let globeRect = NSRect(x: Self.globeInkOrigin.x - globe.ink.minX * gk,
                               y: Self.globeInkOrigin.y - globe.ink.minY * gk,
                               width: gSize.width * gk, height: gSize.height * gk)
        // A ".circle.fill" badge carries its own solid disc with the glyph in negative
        // space, which is what makes it readable at this size — a bare lock outline
        // was competing with the globe's own strokes.
        //
        // An SF Symbol image is a padded box, not a tight crop: at pointSize 12 a
        // ".circle.fill" reports a 14x14 image holding a 12pt disc, with the 1pt of
        // padding split evenly on each side. Two consequences:
        //
        //  - The point size IS the disc diameter, so ask for the size we want.
        //  - Aspect-fitting the reported box into a target rect shrinks the disc by
        //    the padding. The previous code fitted a 12x11 box into 10x10 and got a
        //    9.12pt disc when it wanted 10 — the reason the badge read as too small.
        //
        // So the badge is drawn at its natural size, centred: because the padding is
        // symmetric, centring the box centres the disc.
        let badgeCfg = NSImage.SymbolConfiguration(pointSize: Self.badgeDiameter,
                                                  weight: .regular)
        var stockBadge: NSImage?
        if case let .symbol(name) = badge {
            stockBadge = NSImage(systemSymbolName: name, accessibilityDescription: describing)?
                .withSymbolConfiguration(badgeCfg)
        }

        // Drawn through a handler rather than lockFocus so it re-renders per display
        // scale instead of being captured once at 1x and upscaled.
        let img = NSImage(size: Self.iconCanvas, flipped: false) { _ in
            globe.image.draw(in: globeRect)
            if case .none = badge { return true }

            // Punch a hole slightly larger than the badge before drawing it. In a
            // template image only alpha matters, so destinationOut erases; without
            // it the badge and the globe's strokes interleave and neither reads.
            let d = Self.badgeDiameter + 2 * Self.badgeRing
            let hole = NSRect(x: Self.badgeCenter.x - d / 2, y: Self.badgeCenter.y - d / 2,
                              width: d, height: d)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: hole).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            switch badge {
            case .none:
                break
            case .symbol:
                guard let stockBadge else { break }
                let s = stockBadge.size
                stockBadge.draw(in: NSRect(x: Self.badgeCenter.x - s.width / 2,
                                           y: Self.badgeCenter.y - s.height / 2,
                                           width: s.width, height: s.height))
            case .lock:
                NSColor.black.setFill()
                NSBezierPath(ovalIn: Self.badgeDisc).fill()
                // A bare disc still reads as "not disconnected", so a missing glyph
                // degrades rather than losing the state entirely.
                guard let lock = Self.lockGlyph else { break }
                // Scale by the measured ink so the lock reaches exactly the intended
                // share, then offset so that ink — not the padded box — is centred.
                let k = Self.badgeDiameter * Self.lockShareOfBadge / lock.ink.height
                let n = lock.image.size
                lock.image.draw(in: NSRect(x: Self.badgeCenter.x - lock.ink.midX * k,
                                           y: Self.badgeCenter.y - lock.ink.midY * k,
                                           width: n.width * k, height: n.height * k),
                                from: .zero, operation: .destinationOut, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = true
        // The composed image is a fresh NSImage, so it does not inherit the source
        // symbol's description — set it here or the menu bar item has none at all.
        img.accessibilityDescription = describing
        return img
    }

    func updateButton() {
        guard let button = statusItem.button else { return }
        let icon = iconImage()
        // A nil icon means an empty button, and with no title that is a zero-width item
        // — the app running with nothing to click. Complain once rather than on every
        // poll, because the glyphs are built in cached statics: if it fails it fails
        // for the life of the process, and the log should say so exactly once.
        if icon == nil, !Self.warnedAboutMissingIcon {
            Self.warnedAboutMissingIcon = true
            NSLog("AnywayConnect: iconImage() returned nil — the menu bar item will be "
                + "invisible. globeGlyph=\(Self.globeGlyph == nil ? "nil" : "ok")")
        }
        button.image = icon; button.imagePosition = .imageLeading
        var title = ""
        if ConfigStore.shared.config.general.menubar.showEndpointName, case let .connected(key, _) = state {
            title = " " + menuBarName(for: key)
        }
        button.title = title
    }

    // MARK: - Refresh + auto-reconnect

    func refresh() {
        let newState = VPNRunner.shared.currentState()
        if case .connected = state, case .disconnected = newState, !busy, !userInitiatedDisconnect {
            handleUnexpectedDisconnect()
        }
        state = newState
        if case let .connected(key, _) = newState { lastEndpointKey = key; reconnectAttempts = 0 }
        updateButton(); rebuildMenu()
    }

    func handleUnexpectedDisconnect() {
        let ar = ConfigStore.shared.config.general.autoReconnect
        guard ar.enabled, let key = lastEndpointKey else { return }
        guard reconnectAttempts < ar.maxRetries else { notify("Auto-reconnect gave up"); return }
        reconnectAttempts += 1
        notify("Dropped — reconnecting (\(reconnectAttempts)/\(ar.maxRetries))…")
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(ar.retryDelaySeconds)) { [weak self] in
            self?.startConnect(key)
        }
    }

    // MARK: - Actions

    func labelFor(_ key: String) -> String {
        ConfigStore.shared.endpoint(inActiveProfile: key)?.label ?? key
    }

    /// Text shown next to the menu bar icon: the endpoint's label, the same
    /// wording used in the menu, truncated so a long one can't crowd the menu
    /// bar. Falls back to the key if the endpoint has since been removed.
    func menuBarName(for key: String) -> String {
        let label = labelFor(key)
        let limit = 18
        guard label.count > limit else { return label }
        return label.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    @objc func connectMenu(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        userInitiatedDisconnect = false
        if case .connected = state { switchTo(key) } else { startConnect(key) }
    }

    func switchTo(_ key: String) {
        if busy { return }
        // Set before the disconnect half, so the menu marks the destination for the
        // whole switch rather than only once the connect phase starts.
        connectingKey = key
        busy = true; updateButton(); rebuildMenu()
        notify("Switching to \(labelFor(key))…")
        VPNRunner.shared.disconnect { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.busy = false; self?.startConnect(key) }
        }
    }

    /// Escape hatch for a connect that isn't finishing.
    ///
    /// Kills the authentication child, which is what unblocks the reader waiting on
    /// its pipes. If there is nothing to kill the UI is wedged for some other
    /// reason, so clear `busy` regardless rather than leaving the user stuck.
    @objc func cancelBusy() {
        guard busy else { return }
        let killed = VPNRunner.shared.cancelInFlight()
        notify(killed ? "Stopping…" : "Cancelled")
        if !killed {
            stopBusyWatchdog()
            busy = false
            connectingKey = nil
            refresh()
        }
    }

    /// Last-resort guard against a permanently stuck UI.
    ///
    /// The authentication step is time-bounded now, so completion should always
    /// arrive. This exists because the cost of being wrong is a menu bar that never
    /// recovers, and the cost of the guard is a timer.
    private func startBusyWatchdog() {
        stopBusyWatchdog()
        busyWatchdog = Timer.scheduledTimer(withTimeInterval: 240, repeats: false) { [weak self] _ in
            guard let self = self, self.busy else { return }
            NSLog("AnywayConnect: connect never completed; clearing busy state")
            VPNRunner.shared.cancelInFlight()
            self.busy = false
            self.connectingKey = nil
            self.notify("Connect gave up — see Logs")
            self.refresh()
        }
    }

    private func stopBusyWatchdog() {
        busyWatchdog?.invalidate()
        busyWatchdog = nil
    }

    func startConnect(_ key: String) {
        if busy { return }
        guard let profile = ConfigStore.shared.activeProfile else { notify("No active profile"); return }
        connectingKey = key
        busy = true; updateButton(); rebuildMenu()
        startBusyWatchdog()
        notify("Connecting to \(labelFor(key))… complete SSO in the browser.")
        VPNRunner.shared.connect(profile: profile, endpointKey: key, force: true) { [weak self] result in
            guard let self = self else { return }
            self.stopBusyWatchdog()
            self.busy = false
            self.connectingKey = nil
            self.notify(result.ok ? "Connected: \(self.labelFor(key))"
                                  : "Connect failed: \(result.message)")
            self.refresh()
            // A notification is fine for most failures, but a rejected auth group
            // has a specific, known remedy — so ask instead of leaving the user to
            // guess from a one-line message.
            if !result.ok, !result.advertisedGroups.isEmpty {
                self.offerAuthGroupFix(result, profileID: profile.id)
            }
        }
    }

    /// Offer to save one of the groups the gateway actually advertises.
    ///
    /// Saved onto the *endpoint*, not the profile, because the list came from that
    /// one host: writing it profile-wide would risk breaking the endpoints that
    /// were working. Nothing is saved unless the user picks.
    private func offerAuthGroupFix(_ result: VPNRunner.ConnectResult, profileID: String) {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 25))
        popup.addItems(withTitles: result.advertisedGroups)

        let a = NSAlert()
        a.messageText = "That gateway rejected the auth group"
        let had = result.currentAuthgroup.isEmpty
            ? "No auth group was sent."
            : "It was sent “\(result.currentAuthgroup)”, which it doesn't offer."
        a.informativeText = "\(had)\n\n\(result.host) accepts the "
            + "\(result.advertisedGroups.count == 1 ? "group" : "groups") below. "
            + "Saving applies to this endpoint only."
        a.accessoryView = popup
        a.addButton(withTitle: "Save & Retry")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let chosen = popup.titleOfSelectedItem ?? ""
        guard !chosen.isEmpty else { return }
        ConfigStore.shared.update { c in
            guard let p = c.profiles.firstIndex(where: { $0.id == profileID }),
                  let e = c.profiles[p].endpoints
                    .firstIndex(where: { $0.key == result.endpointKey }) else { return }
            c.profiles[p].endpoints[e].authgroup = chosen
        }
        startConnect(result.endpointKey)
    }

    @objc func disconnectMenu() {
        if busy { return }
        userInitiatedDisconnect = true
        // Nothing is being connected to, so no endpoint should show as in progress
        // while this runs — `busy` alone would otherwise be ambiguous.
        connectingKey = nil
        busy = true; updateButton(); rebuildMenu()
        VPNRunner.shared.disconnect { [weak self] in
            self?.busy = false; self?.notify("Disconnected"); self?.refresh()
        }
    }

    @objc func switchProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ConfigStore.shared.setActiveProfile(id: id)
        refresh()
        if let name = ConfigStore.shared.activeProfile?.name { notify("Active profile: \(name)") }
    }

    @objc func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        settingsWC?.reloadFromConfig()
        settingsWC?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The standard About panel rather than a window of our own.
    ///
    /// It already lays out the icon, name and version the way users expect, and takes the
    /// name and version straight from the bundle so they cannot drift from what shipped.
    /// A hand-built dialog would be more code for a worse match.
    @objc func showAbout() {
        // Required, not optional: an accessory app is not frontmost, so without this the
        // panel opens behind whatever is.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: Self.aboutPanelOptions())
    }

    /// Split from `showAbout` so the panel's contents can be inspected without activating
    /// the app — a test harness that steals focus is a nuisance to whoever is at the
    /// keyboard.
    static func aboutPanelOptions() -> [NSApplication.AboutPanelOptionKey: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? short

        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let credits = NSAttributedString(
            string: "A menu bar client for OpenConnect VPNs.\n"
                  + "Tunnels are run by openconnect, with privileged work handed to a "
                  + "signed helper daemon.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: centred])

        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "AnywayConnect",
            .applicationVersion: short,
            .applicationIcon: AppIcon.standard,
            .credits: credits,
        ]
        // Only when it says something the version above doesn't: with both at 1.0 this
        // would otherwise render an empty "(1.0)" alongside it.
        if build != short { options[.version] = build }
        return options
    }

    @objc func doRefresh() { refresh() }
    @objc func quitApp() { NSApp.terminate(nil) }

    // MARK: - Menu

    func rebuildMenu() {
        statusItem.menu = buildMenu()
        // The Dock fallback shows this same menu, so it has to be rebuilt alongside —
        // otherwise it would freeze at whatever the state was when the fallback engaged.
        if dockFallbackEngaged { installFallbackMainMenu() }
    }

    /// Returns a fresh menu rather than assigning it, because it now has two homes: the
    /// status item, and the Dock/main menu used when the icon cannot be placed. A single
    /// NSMenu cannot be attached in two places, so each caller gets its own.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // Without this AppKit auto-enables any item whose target responds to its
        // action, which silently overrode the `isEnabled = !busy` below — the
        // endpoint items stayed clickable mid-connect (harmless, since the
        // handlers bail on `busy`, but it read as though nothing happened).
        menu.autoenablesItems = false
        let cfg = ConfigStore.shared.config
        let profile = ConfigStore.shared.activeProfile

        // A coloured dot rather than a glyph: connection state is a traffic light, and the
        // colour carries it at a glance where a shape has to be read. Replaces the ●/○
        // bullets that used to be part of the title text, which no column could align.
        let statusTitle: String
        let statusColor: NSColor
        switch stateForIcon() {
        case .connecting:
            statusTitle = "Working…"; statusColor = .systemOrange
        case .connected:
            statusColor = .systemGreen
            if case let .connected(key, _) = state { statusTitle = "Connected: \(labelFor(key))" }
            else { statusTitle = "Connected" }
        case .disconnected:
            statusTitle = "Disconnected"; statusColor = .tertiaryLabelColor
        }
        addDisabled(menu, statusTitle, Self.statusDot(statusColor))
        // The leading spaces these two used to carry are gone as well — the image column
        // already sets the left edge, and hand-made indents fought it.
        if let p = profile { addDisabled(menu, "Profile: \(p.name)", sym("folder")) }
        if case let .connected(_, host) = state { addDisabled(menu, host, sym("network")) }

        // While busy, this is the only enabled action in the menu — every other
        // item is disabled on `busy`. Without it a connect that never finishes left
        // no way back short of quitting the app.
        if busy {
            menu.addItem(.separator())
            let cancel = item("Stop Connecting", #selector(cancelBusy), ".", sym("stop.circle"))
            cancel.isEnabled = true
            menu.addItem(cancel)
        }
        menu.addItem(.separator())

        // Zero profiles is a legitimate state (a fresh install), so say so and
        // point at the way out rather than showing an empty "Connect to" header.
        let hasEndpoints = !(profile?.endpoints.isEmpty ?? true)
        if !hasEndpoints {
            addDisabled(menu, profile == nil ? "No profiles configured" : "No endpoints in this profile",
                        sym("exclamationmark.triangle"))
            menu.addItem(item("Set up in Settings…", #selector(openSettings), ",", sym("gearshape")))
            menu.addItem(.separator())
            menu.addItem(item("Refresh status", #selector(doRefresh), "r", sym("arrow.clockwise")))
            menu.addItem(.separator())
            menu.addItem(item("Quit AnywayConnect", #selector(quitApp), "q", sym("xmark.rectangle")))
            return menu
        }

        if case .connected = state {
            menu.addItem(item("Disconnect", #selector(disconnectMenu), "d", sym("bolt.slash")))
            menu.addItem(.separator())
            addDisabled(menu, "Switch endpoint", sym("arrow.left.arrow.right"))
        } else {
            addDisabled(menu, "Connect to", sym("bolt"))
        }

        // Endpoints from the active profile.
        //
        // Favourites are the way to pin endpoints to the top level. With none
        // chosen there is nothing to rank by, so list them all rather than an
        // arbitrary slice — the old "first three in config order" looked like a
        // deliberate choice but was really just whatever happened to be first.
        if let p = profile {
            let favs = p.endpoints.filter { $0.favorite }
            let pinned = favs.isEmpty ? p.endpoints : favs
            for ep in pinned {
                // mark() decides the image: a tick for the one in use, nothing for the rest.
                let it = item(ep.label, #selector(connectMenu(_:)), "", nil)
                it.representedObject = ep.key; it.isEnabled = !busy
                mark(it, ep.key)
                menu.addItem(it)
            }
            // Only worth a submenu when it would reveal something not already
            // listed above.
            if p.endpoints.count > pinned.count {
                let allItem = NSMenuItem(title: "All endpoints", action: nil, keyEquivalent: "")
                allItem.image = sym("list.bullet")
                let allMenu = NSMenu()
                allMenu.autoenablesItems = false
                for ep in p.endpoints {
                    let it = item(ep.label, #selector(connectMenu(_:)), "", nil)
                    it.representedObject = ep.key; it.isEnabled = !busy
                    mark(it, ep.key)
                    allMenu.addItem(it)
                }
                allItem.submenu = allMenu
                // Disable the parent too, not just its children. Left enabled it
                // still opened, revealing a submenu where nothing can be clicked —
                // which reads as the app ignoring you rather than as busy.
                allItem.isEnabled = !busy
                menu.addItem(allItem)
            }
        }

        // Profile switcher.
        if cfg.profiles.count > 1 {
            menu.addItem(.separator())
            let profItem = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
            profItem.image = sym("folder")
            let profMenu = NSMenu()
            for p in cfg.profiles {
                // Same treatment as the endpoints: only the active one is ticked, and the
                // rest are left unmarked rather than repeating a folder on every row.
                let active = p.id == cfg.activeProfileID
                let it = item(p.name, #selector(switchProfile(_:)), "",
                              active ? sym("checkmark") : nil)
                it.representedObject = p.id
                profMenu.addItem(it)
            }
            profItem.submenu = profMenu
            menu.addItem(profItem)
        }

        menu.addItem(.separator())
        // Mirrors Settings ▸ General. It's a display preference rather than an action, so
        // it stays available while busy.
        //
        // Worded as the action it performs rather than carrying a checkmark. Both are
        // ordinary on macOS — "Show/Hide Sidebar" is this exact pattern — and with a symbol
        // in every row there is no checkmark column left to report state in anyway.
        let showingName = cfg.general.menubar.showEndpointName
        let nameItem = item(showingName ? "Hide endpoint name" : "Show endpoint name",
                            #selector(toggleEndpointName), "",
                            sym(showingName ? "eye.slash" : "eye"))
        // Only has a visible effect once connected, since the title is empty
        // otherwise. Say so rather than letting a toggle appear to do nothing.
        if case .connected = state {} else {
            nameItem.toolTip = "Takes effect in the menu bar while connected"
        }
        menu.addItem(nameItem)
        menu.addItem(item("Refresh status", #selector(doRefresh), "r", sym("arrow.clockwise")))
        // Set explicitly, though macOS 26 would supply a gear here regardless. Better ours
        // than one that appears by magic in exactly one row.
        menu.addItem(item("Settings…", #selector(openSettings), ",", sym("gearshape")))
        menu.addItem(item("About AnywayConnect", #selector(showAbout), "", sym("info.circle")))
        menu.addItem(.separator())
        // A boxed cross, as Rectangle and Karabiner both use for Quit. `power` read as
        // "shut down the machine" rather than "close this app".
        //
        // `.rectangle`, which is landscape at 18x14, not `.square`/`.app` — those two are
        // the same 15x14 glyph as each other, so swapping between them changes nothing.
        menu.addItem(item("Quit AnywayConnect", #selector(quitApp), "q", sym("xmark.rectangle")))
        return menu
    }

    /// Mark an endpoint row: connected, connecting, or neither.
    ///
    /// Only the endpoint you are on is marked. Giving every endpoint a globe filled the
    /// column with a glyph that said nothing — each row is an endpoint, so drawing that on
    /// all of them is noise, and it left the one row that mattered competing with a dozen
    /// identical neighbours. Unmarked rows still line up: one image anywhere in the section
    /// reserves the column for all of it.
    ///
    /// Still a literal tick, as a macOS menu uses for "this is the current one" — the Wi-Fi
    /// menu included — but in the image column rather than the checkmark column beside it.
    /// `.on`/`.mixed` reserved a second column no other row wanted, which indented the rows
    /// carrying symbols away from the rows that weren't.
    ///
    /// An earlier attempt put a custom `ellipsis` in the *state* column and it sat out of
    /// line: a 13x5 symbol where AppKit expects ~18x17. In the image column that constraint
    /// is gone, so a connect in progress can be shown honestly.
    ///
    /// An image survives `isEnabled = false`, which matters: every endpoint row is disabled
    /// while busy, and the in-progress mark has to show precisely then.
    private func mark(_ item: NSMenuItem, _ key: String) {
        if case let .connected(connectedKey, _) = state, connectedKey == key {
            item.image = sym("checkmark")
        } else if busy, connectingKey == key {
            item.image = sym("ellipsis")
        } else {
            item.image = nil
        }
    }

    /// An SF Symbol for a menu row, or nil where a row is deliberately unmarked.
    ///
    /// A row's image is what sets the title's left edge. A menu reserves that column per
    /// section between separators, so a section needs only *one* image for every title in
    /// it to line up — which is why unmarked rows still sit correctly beside marked ones.
    /// macOS 26 supplies a gear for "Settings…" unasked, and it was that lone image
    /// indenting one section and nothing else that made the padding look arbitrary.
    private func sym(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// A coloured status dot, drawn rather than borrowed from SF Symbols.
    ///
    /// Centred in the same 16pt box the symbols occupy, so the column keeps one geometry:
    /// a bare `circle.fill` at dot size would be narrower than its neighbours and sit off
    /// their axis. Colour is the whole point — the same green, amber and grey the Settings
    /// pane already uses for the helper's state, so the two read as one vocabulary.
    ///
    /// Resolved against the appearance in force when it is drawn. The menu is rebuilt on
    /// every status poll, so a switch to dark mode is picked up within seconds.
    private static func statusDot(_ color: NSColor) -> NSImage {
        let box: CGFloat = 16, diameter: CGFloat = 9
        let img = NSImage(size: NSSize(width: box, height: box))
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: (box - diameter) / 2, y: (box - diameter) / 2,
                                    width: diameter, height: diameter)).fill()
        img.unlockFocus()
        return img
    }

    private func addDisabled(_ menu: NSMenu, _ title: String, _ image: NSImage?) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        i.image = image
        menu.addItem(i)
    }
    private func item(_ title: String, _ action: Selector, _ key: String,
                      _ image: NSImage?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.image = image
        return i
    }

    func notify(_ text: String) {
        let n = NSUserNotification(); n.title = "AnywayConnect"; n.informativeText = text
        NSUserNotificationCenter.default.deliver(n)
    }
}
