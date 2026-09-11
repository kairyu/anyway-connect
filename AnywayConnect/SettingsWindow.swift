import AppKit
import ServiceManagement
import UniformTypeIdentifiers

// ── Settings window ──────────────────────────────────────────────────────────
// Follows the macOS settings-window conventions collected by usagimaru
// (https://zenn.dev/usagimaru/articles/b2a328775124ef), which fill in the gaps
// the current HIG leaves implicit:
//
//   • NSToolbar in `.preference` style, tabs always carrying both icon + label,
//     with user customization disabled.
//   • Modeless: every change applies and persists immediately. No Save, Cancel,
//     Apply or Done buttons anywhere.
//   • Only the close button is enabled. Zoom (as "+" Zoom, not Full Screen) is
//     offered only on panes holding a scrollable list; minimize never is.
//   • Escape and ⌘. close the window.
//   • The window title tracks the active pane; the last-used pane is restored.
//   • The window resizes to each pane with animation, honouring Reduce Motion,
//     and the outgoing pane is hidden so content isn't drawn mid-resize.
//   • Two-column form: right-aligned 13pt regular headings ending in a colon,
//     8pt between columns, 11pt secondary-label description text.

private let kLastPaneKey = "SettingsLastPaneIdentifier"

/// Width of the content column: the widest input field, the hints, and the status
/// rows all use it, so the pane has one flush right edge and — more importantly —
/// a width that no text change can alter.
let kHintWidth: CGFloat = 400

/// Status-row text width, sized so the button column right-aligns inside
/// kHintWidth: 12pt light + 6pt gap + text + 8pt gap + widest button group.
let kStatusTextWidth: CGFloat = 200

/// Window subclass: Escape / ⌘. closes, plus the pane-fitting resize animation.
final class SettingsWindow: NSWindow {
    /// True while the window is being resized to fit a pane, so a programmatic
    /// resize isn't mistaken for a user drag and tab clicks can be ignored.
    private(set) var isFittingPane = false

    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    /// Duration scaled by how far the frame has to travel: 0.2s for a nudge,
    /// up to 0.7s for a full-height change. A fixed duration is what makes the
    /// stock resize feel abrupt on big jumps and sluggish on small ones.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        let minDuration = 0.2, maxDuration = 0.7
        let delta = max(abs(newFrame.width - frame.width), abs(newFrame.height - frame.height))
        let reference = NSScreen.main?.frame.height ?? 800
        return minDuration + (maxDuration - minDuration) * min(delta / reference, 1.0)
    }

    /// Resize to a content size with the title bar staying put, rather than the
    /// window growing symmetrically about its centre.
    func fit(contentSize: NSSize, animate: Bool, completion: @escaping () -> Void) {
        let contentFrame = frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        let heightDiff = frame.height - contentFrame.height
        let newFrame = NSRect(x: frame.origin.x, y: frame.origin.y + heightDiff,
                              width: contentFrame.width, height: contentFrame.height)
        isFittingPane = true
        // setFrame(_:display:animate:) blocks for the animation's duration, so
        // the completion runs once the frame has actually settled.
        setFrame(newFrame, display: true, animate: animate && !reduceMotion)
        isFittingPane = false
        completion()
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let general = GeneralPane()
    let profiles = ProfilesPane()
    let logs = LogsPane()
    private var tabVC: SettingsTabViewController!

    convenience init() {
        // Placeholder frame; the tab controller sizes the window per pane.
        let win = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                                 styleMask: [.titled, .closable],
                                 backing: .buffered, defer: false)
        // Zoom appears as the traditional "+" Zoom rather than Full Screen.
        win.collectionBehavior.insert(.fullScreenAuxiliary)
        self.init(window: win)
        buildUI()
    }

    private func buildUI() {
        guard let window = window else { return }

        let tab = SettingsTabViewController()
        tab.tabStyle = .toolbar

        let panes: [(SettingsPane, String, String)] = [
            (general,  "General",  "gearshape"),
            (profiles, "Profiles", "list.bullet.rectangle"),
            (logs,     "Logs",     "doc.plaintext"),
        ]
        for (vc, label, symbol) in panes {
            vc.title = label
            let item = NSTabViewItem(viewController: vc)
            item.identifier = label
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            tab.addTabViewItem(item)
        }

        tabVC = tab
        window.contentViewController = tab
        window.toolbarStyle = .preference
        window.toolbar?.allowsUserCustomization = false
        window.toolbar?.displayMode = .iconAndLabel
        window.delegate = self
        window.center()

        // Restore the pane last used, per "Restore the last-displayed panel".
        if let saved = UserDefaults.standard.string(forKey: kLastPaneKey),
           let idx = panes.firstIndex(where: { $0.1 == saved }) {
            tab.selectedTabViewItemIndex = idx
        }
    }

    func reloadFromConfig() {
        general.reload()
        profiles.reload()
        logs.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        logs.stopTimer()
        general.stopHelperPolling()
    }
}

// ── Tab controller ───────────────────────────────────────────────────────────

// Switching panes is sequenced deliberately, following MacAppSettingsUI:
//
//   1. A blank stand-in replaces the outgoing pane, so no real content is drawn
//      stretched while the frame is in motion.
//   2. The window animates to the incoming pane's size.
//   3. Only once the frame has settled is the pane put in place and cross-faded.
//
// Letting NSTabViewController's own `.crossfade` run concurrently with its
// automatic window resize is what made the transition look janky: the content
// was being scaled and faded against a frame that was still moving.
final class SettingsTabViewController: NSTabViewController {
    private let standIn = NSView()
    private var presentingItem: NSTabViewItem?
    private var hasAppeared = false

    private var settingsWindow: SettingsWindow? { view.window as? SettingsWindow }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The fade is run by hand after the resize, not by the tab view.
        transitionOptions = []
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        hasAppeared = true
        if let item = tabView.selectedTabViewItem { present(item, animate: false) }
    }

    override func tabView(_ tabView: NSTabView, shouldSelect tabViewItem: NSTabViewItem?) -> Bool {
        // Ignore a repeat click on the current tab, and any click landing while
        // a transition is still running.
        if let tabViewItem, presentingItem === tabViewItem { return false }
        if settingsWindow?.isFittingPane == true { return false }
        return super.tabView(tabView, shouldSelect: tabViewItem)
    }

    override func transition(from fromViewController: NSViewController,
                             to toViewController: NSViewController,
                             options: NSViewController.TransitionOptions = [],
                             completionHandler completion: (() -> Void)? = nil) {
        // Stand a blank view in for the outgoing pane, then report done. The
        // incoming pane is placed later, once the window has finished resizing.
        if let container = fromViewController.view.superview {
            standIn.frame = container.bounds
            container.replaceSubview(fromViewController.view, with: standIn)
        }
        completion?()
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let tabViewItem else { return }
        present(tabViewItem, animate: hasAppeared)
    }

    private func present(_ item: NSTabViewItem, animate: Bool) {
        guard let win = settingsWindow, let pane = item.viewController as? SettingsPane else { return }
        presentingItem = item
        pane.loadViewIfNeeded()

        applySizeLimits(for: pane, in: win)
        win.fit(contentSize: pane.paneContentSize(), animate: animate) { [weak self] in
            guard let self = self else { return }
            self.placePane(pane, fade: animate)
            // "Update the window title to match the currently displayed panel."
            win.title = pane.title ?? item.label
            self.applyWindowButtons(for: pane, in: win)
            pane.applyFocus(in: win)
            if let id = item.identifier as? String {
                UserDefaults.standard.set(id, forKey: kLastPaneKey)
            }
        }
    }

    /// Swap the stand-in for the real pane in one transaction so no intermediate
    /// size is drawn, cross-fading the container as it goes.
    private func placePane(_ pane: SettingsPane, fade: Bool) {
        // Resizing the window by hand leaves the tab view holding whatever size
        // it had before, so reconcile the container with the new content rect
        // before handing the pane its frame. Skipping this leaves the pane
        // sized against a stale (and sometimes zero-height) container, which
        // renders as an empty window.
        tabView.frame = view.bounds

        guard let container = standIn.superview ?? pane.view.superview else { return }

        if fade, !(settingsWindow?.reduceMotion ?? false) {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.18
            t.timingFunction = CAMediaTimingFunction(name: .easeOut)
            container.wantsLayer = true
            container.layer?.add(t, forKey: "paneFade")
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pane.view.autoresizingMask = [.width, .height]
        pane.view.frame = container.bounds
        if standIn.superview === container {
            container.replaceSubview(standIn, with: pane.view)
        }
        view.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }

    /// Zoom / resizing only for panes holding a scrollable list; minimize never.
    private func applyWindowButtons(for pane: SettingsPane, in win: NSWindow) {
        if pane.isResizablePane { win.styleMask.insert(.resizable) }
        else { win.styleMask.remove(.resizable) }
        win.standardWindowButton(.miniaturizeButton)?.isEnabled = false
    }

    private func applySizeLimits(for pane: SettingsPane, in win: NSWindow) {
        guard pane.isResizablePane else {
            win.contentMinSize = .zero
            win.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                        height: CGFloat.greatestFiniteMagnitude)
            return
        }
        let natural = pane.paneContentSize()
        win.contentMinSize = NSSize(width: pane.minimumWidth, height: max(260, natural.height - 220))
        win.contentMaxSize = NSSize(width: 1400, height: 1200)
    }
}

// ── Shared pane scaffolding ──────────────────────────────────────────────────

class SettingsPane: NSViewController {
    /// Natural pane width, applied at low priority so resizing still works.
    var naturalWidth: CGFloat { 520 }
    var minimumWidth: CGFloat { 440 }
    var padding: CGFloat { 20 }
    /// True for panes containing a scrollable list, which per the guideline may
    /// offer the zoom button and window resizing.
    var isResizablePane: Bool { false }

    /// Subclasses return the pane's single root content view.
    func content() -> NSView { NSView() }

    override func loadView() {
        let root = NSView()
        let body = content()
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)

        let naturalW = root.widthAnchor.constraint(equalToConstant: naturalWidth)
        naturalW.priority = .defaultLow
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: padding),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: padding),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -padding),
            body.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -padding),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth),
            naturalW,
        ])
        view = root
    }

    /// Measured once, before the pane is ever placed in the window. Measuring
    /// later would read back whatever frame the previous pane left behind.
    private var measuredSize: NSSize = .zero

    override func viewDidLoad() {
        super.viewDidLoad()
        view.layoutSubtreeIfNeeded()
        measuredSize = view.fittingSize
        preferredContentSize = measuredSize
    }

    /// The content size the window should take for this pane.
    func paneContentSize() -> NSSize {
        if measuredSize.width > 0 && measuredSize.height > 0 { return measuredSize }
        view.layoutSubtreeIfNeeded()
        return view.fittingSize
    }

    // MARK: - Focus and tab order

    /// Controls in the order Tab should walk them. The first also becomes the
    /// pane's initial first responder.
    ///
    /// Without this AppKit derives the loop geometrically and, since only text
    /// fields join it unless Full Keyboard Access is on, focus landed on
    /// whichever text field happened to come first — "Max retries", four rows
    /// down — and tabbing skipped every pop-up and checkbox.
    var focusChain: [NSView] { [] }

    func applyFocus(in window: NSWindow) {
        let chain = focusChain
        guard !chain.isEmpty else {
            window.initialFirstResponder = nil
            window.makeFirstResponder(nil)
            return
        }
        window.autorecalculatesKeyViewLoop = false
        for (i, v) in chain.enumerated() {
            v.nextKeyView = chain[(i + 1) % chain.count]
        }
        window.initialFirstResponder = chain[0]
        window.makeFirstResponder(chain[0])
    }

    // MARK: - Form builders

    /// Right-aligned heading: system font, regular, 13pt, ends with a colon.
    func formLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13)
        l.alignment = .right
        return l
    }

    func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    /// Description text: 11pt, secondary label colour.
    ///
    /// Always width-constrained. An unconstrained label reports its whole string
    /// as its intrinsic width, and since the window sizes itself to the pane's
    /// fittingSize, that let a *text change* resize the window — visibly, because
    /// the helper status polls every two seconds. Pinning the width moves the
    /// variation into wrapped height instead, and callers that must not move at
    /// all use `fixedLines:` to reserve the space up front.
    func hint(_ s: String, width: CGFloat = kHintWidth, fixedLines: Int? = nil) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.isSelectable = false
        l.translatesAutoresizingMaskIntoConstraints = false
        l.preferredMaxLayoutWidth = width
        l.widthAnchor.constraint(equalToConstant: width).isActive = true
        if let lines = fixedLines {
            l.maximumNumberOfLines = lines
            // Reserve the full height regardless of the current string, so swapping
            // in a shorter or longer message cannot shift anything below it.
            let lineHeight = ceil(l.font!.boundingRectForFont.height)
            l.heightAnchor.constraint(equalToConstant: lineHeight * CGFloat(lines)).isActive = true
        }
        return l
    }

    /// Small coloured dot for a status row. An SF Symbol rather than a drawn
    /// circle so it picks up the system's rendering and stays crisp at any scale.
    func statusLight() -> NSImageView {
        let v = NSImageView()
        v.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        v.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        v.contentTintColor = .tertiaryLabelColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 12).isActive = true
        return v
    }

    /// Text beside a status light. Width-pinned so the button column to its right
    /// lands in the same place on every row and can't move as the text changes.
    func statusText(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13)
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: kStatusTextWidth).isActive = true
        return l
    }

    /// Single-line hint for values that are inherently long, like filesystem
    /// paths: truncated in the middle (which keeps both ends readable) with the
    /// full text in a tooltip so nothing is actually lost.
    func pathHint(_ s: String, width: CGFloat = kHintWidth) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byTruncatingMiddle
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: width).isActive = true
        return l
    }

    func check(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    func field(width: CGFloat, id: String, delegate: NSTextFieldDelegate?) -> NSTextField {
        let tf = NSTextField()
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.identifier = NSUserInterfaceItemIdentifier(id)
        tf.delegate = delegate
        tf.widthAnchor.constraint(equalToConstant: width).isActive = true
        return tf
    }

    func button(_ title: String, _ action: Selector, width: CGFloat? = nil,
                small: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        if small { b.controlSize = .small; b.font = .systemFont(ofSize: 11) }
        b.translatesAutoresizingMaskIntoConstraints = false
        if let w = width { b.widthAnchor.constraint(equalToConstant: w).isActive = true }
        return b
    }

    /// Small square icon button, as used for +/− beneath a list.
    func iconButton(_ symbol: String, _ action: Selector, tooltip: String) -> NSButton {
        let b = NSButton()
        b.title = ""
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        b.imagePosition = .imageOnly
        b.bezelStyle = .smallSquare
        b.setButtonType(.momentaryPushIn)
        b.target = self
        b.action = action
        b.toolTip = tooltip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }

    /// Horizontal group of controls occupying one grid cell.
    func hrow(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .firstBaseline
        s.spacing = spacing
        return s
    }

    /// Two-column form: right-aligned headings, controls on the trailing side,
    /// 8pt between the columns.
    func form(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        if grid.numberOfColumns > 1 { grid.column(at: 1).xPlacement = .leading }
        for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .center }
        return grid
    }

    /// Horizontal separator for a clear semantic division between groups.
    func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    func column(_ views: [NSView], spacing: CGFloat = 14) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    func notifyAppDelegate() {
        (NSApp.delegate as? AppDelegate)?.refresh()
    }
}

// ── General pane ─────────────────────────────────────────────────────────────
final class GeneralPane: SettingsPane, NSTextFieldDelegate {
    override var naturalWidth: CGFloat { 540 }

    private var showName: NSButton!
    private var launchAtLogin: NSButton!
    private var autoReconnect: NSButton!
    private var maxRetries: NSTextField!
    private var retryDelay: NSTextField!
    private var openconnectField: NSTextField!
    private var detectedLabel: NSTextField!
    private var activeProfilePopup: NSPopUpButton!
    private var profileIDsInPopup: [String] = []
    private var approvalLight: NSImageView!
    private var approvalText: NSTextField!
    private var installLight: NSImageView!
    private var installText: NSTextField!
    private var helperInstallButton: NSButton!
    private var helperRemoveButton: NSButton!
    private var helperApprovalButton: NSButton!
    private var helperHint: NSTextField!
    private var helperRouteHint: NSTextField!
    private var helperVersionHint: NSTextField!
    private var helperDivider: NSBox!
    private var backendPopup: NSPopUpButton!
    private var helperTimer: Timer?
    private var loading = false

    override func content() -> NSView {
        activeProfilePopup = NSPopUpButton()
        activeProfilePopup.target = self
        activeProfilePopup.action = #selector(apply)
        activeProfilePopup.translatesAutoresizingMaskIntoConstraints = false
        activeProfilePopup.widthAnchor.constraint(equalToConstant: 260).isActive = true

        showName = check("Show endpoint name in the menu bar", #selector(apply))
        // Deliberately NOT wired to apply(): launch-at-login is a system registration,
        // not a value in our config file. Its truth lives in SMAppService.mainApp,
        // which the user can change in System Settings without telling us, so a stored
        // bool would be free to disagree with reality — the same class of bug that had
        // the privileged daemon reporting healthy while macOS had switched it off.
        launchAtLogin = check("Launch AnywayConnect at login", #selector(toggleLaunchAtLogin))
        autoReconnect = check("Reconnect automatically if the tunnel drops", #selector(apply))
        maxRetries = field(width: 52, id: "maxRetries", delegate: self)
        retryDelay = field(width: 52, id: "retryDelay", delegate: self)
        openconnectField = field(width: kHintWidth, id: "openconnectPath", delegate: self)
        // "Automatic" is how macOS labels a field whose value it works out for
        // you; "blank = auto-detect" described the mechanism instead of the
        // result and read like a code comment.
        openconnectField.placeholderString = "Automatic"
        detectedLabel = pathHint("Detected: —")

        // Two rows because there are two things the user has to get done, but they
        // are NOT independent gates — they are consecutive phases of one
        // SMAppService.Status:
        //
        //   .notRegistered --register()--> .requiresApproval --user toggle--> .enabled
        //          ^                              |                              |
        //          +--------- unregister() -------+------------------------------+
        //
        // Registration comes first and creates the Login Items entry; approval is
        // only possible afterwards. So only four display states are reachable, one
        // per status: approved-but-unregistered cannot happen.
        approvalLight = statusLight()
        approvalText = statusText("—")
        installLight = statusLight()
        installText = statusText("—")

        // Which privileged backend to provision. Two genuinely different
        // mechanisms, and the choice isn't always the user's to make: an ad-hoc
        // signed build has no team, so the daemon's code requirement can never be
        // satisfied and PrivilegedClient fails closed. That build can still use the
        // sudo helper, so the option has to exist rather than being unreachable.
        backendPopup = NSPopUpButton()
        backendPopup.addItems(withTitles: [Self.daemonOptionTitle, Self.helperOptionTitle])
        backendPopup.target = self
        backendPopup.action = #selector(backendChanged)
        backendPopup.translatesAutoresizingMaskIntoConstraints = false
        backendPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        if currentCodeIdentity() == nil {
            // Explained, not silently missing: the reason is a property of the
            // build, and a disabled item with a tooltip says so.
            backendPopup.item(at: 0)?.isEnabled = false
            backendPopup.toolTip = "The privileged daemon needs an Apple-issued signing "
                + "identity. This build is ad-hoc signed, so only the root helper can be used."
        }

        helperInstallButton = button("Install", #selector(installHelper))
        helperRemoveButton = button("Remove", #selector(removeHelper))
        helperApprovalButton = button("Open Login Items…", #selector(openLoginItems))
        // Apple writes navigation paths with ">" (as in "choose Apple menu >
        // System Settings"), so follow that rather than inventing a glyph.
        helperApprovalButton.toolTip = "System Settings > General > Login Items & Extensions"
        // Split in two on purpose. The explanation never changes, so it can wrap
        // freely; only the short "Currently:" line varies with status, and it is
        // held to one fixed-height line so a poll can't move the layout.
        // Two lines reserved because the text differs per method, and an
        // unconstrained wrapping label would change the pane's height when the
        // method changed. Both variants are written to fit two lines at kHintWidth.
        helperHint = hint(Self.daemonExplanation, fixedLines: 2)
        helperRouteHint = hint("—", fixedLines: 1)
        // fixedLines so the row keeps its height when there is nothing to say,
        // otherwise the pane would grow and shrink as the version resolves.
        helperVersionHint = hint("", fixedLines: 1)
        helperDivider = NSBox()
        helperDivider.boxType = .separator
        helperDivider.translatesAutoresizingMaskIntoConstraints = false

        // Held in locals purely so the padding below can find their rows by identity
        // instead of by number.
        let installStatusRow = statusRow(installLight, installText,
                                        [helperInstallButton, helperRemoveButton])
        let authStatusRow = statusRow(approvalLight, approvalText, [helperApprovalButton])

        let rows: [[NSView]] = [
            // First row, where macOS apps conventionally put this. It sits above the
            // divider even though it is a system registration rather than a stored
            // preference — the convention is what people look for, and being findable
            // matters more here than the tidiness of that boundary.
            [formLabel("Start up:"), launchAtLogin],
            [formLabel("Active profile:"), activeProfilePopup],
            [formLabel("Menu bar:"), showName],
            [formLabel("Auto-reconnect:"), autoReconnect],
            [formLabel("Max retries:"), hrow([maxRetries, label("Delay:"), retryDelay, label("seconds")])],
            [formLabel("openconnect binary:"), openconnectField],
            [NSGridCell.emptyContentView, detectedLabel],
            // Everything above is app preference; everything below is system
            // integration. Padding alone was carrying that boundary too weakly.
            [helperDivider, NSGridCell.emptyContentView],
            [formLabel("Method:"), backendPopup],
            // Ordered to match how macOS actually works: installing is what
            // creates the Login Items entry, so it has to come first. The row
            // below is meaningless until this one is green.
            [formLabel("Privileged helper:"), installStatusRow],
            // Version detail sits under its row in small grey type, the same way
            // "Detected:" sits under the openconnect field. It is a supporting
            // fact, not the status itself, so it shouldn't crowd the status text.
            [NSGridCell.emptyContentView, helperVersionHint],
            // Deliberately a fixed label rather than one that swaps between
            // "Background activity" and "Sudo rule" with the method. The grid sizes
            // its label column to the widest label, so a changing label would
            // resize the pane every time the method changed — the same class of
            // jitter that the hint widths were pinned to avoid. What differs
            // between methods is said in the status text instead.
            [formLabel("Authorization:"), authStatusRow],
            [NSGridCell.emptyContentView, helperHint],
            [NSGridCell.emptyContentView, helperRouteHint],
        ]
        let grid = form(rows)

        // Rows are addressed by the view they contain, never by number. Hardcoded
        // indices here were silently wrong the moment a row was inserted at the top:
        // the merge intended for the divider landed on the "Detected:" row, which then
        // stretched across both columns and collided with the text at the foot of the
        // pane, while the divider itself was left stub-width. Nothing about that fails
        // to compile or trips a test — it just looks broken.
        func row(_ view: NSView) -> NSGridRow? {
            guard let i = rows.firstIndex(where: { $0.contains(where: { $0 === view }) })
            else { return nil }
            return grid.row(at: i)
        }
        row(detectedLabel)?.topPadding = -4
        // Merged across both columns and stretched, so the rule spans the pane.
        // Doing it inside this grid rather than splitting into two grids is what
        // keeps the label column aligned: a second grid would measure its own
        // widest label and the left edge would step.
        if let dividerRow = row(helperDivider) {
            dividerRow.mergeCells(in: NSRange(location: 0, length: grid.numberOfColumns))
            dividerRow.cell(at: 0).xPlacement = .fill
            dividerRow.topPadding = 16
        }
        row(backendPopup)?.topPadding = 14         // Method
        row(installStatusRow)?.topPadding = 8      // Privileged helper
        row(helperVersionHint)?.topPadding = -4    // version detail, hugging the row above
        row(authStatusRow)?.topPadding = 6         // Authorization
        row(helperHint)?.topPadding = 8            // explanation
        row(helperRouteHint)?.topPadding = 2       // current transport
        return column([grid], spacing: 14)
    }

    /// light + text + right-aligned buttons, pinned to the content width so the
    /// two rows align with each other and with the fields above them.
    private func statusRow(_ light: NSImageView, _ text: NSTextField,
                           _ buttons: [NSButton]) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [light, text, spacer] + buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: kHintWidth).isActive = true
        // The spacer absorbs the slack, so hiding a button leaves the others put
        // instead of sliding them across the row.
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        stack.setHuggingPriority(.init(1), for: .horizontal)
        return stack
    }

    private func set(_ light: NSImageView, _ colour: NSColor) {
        light.contentTintColor = colour
    }

    // MARK: - Backend selection

    static let daemonOptionTitle = "Privileged daemon (recommended)"
    static let helperOptionTitle = "Root helper (sudo)"

    static let daemonExplanation =
        "Runs the tunnel as root over a channel only this signed app can use. "
        + "Needs an Apple-issued signing identity."
    static let helperExplanation =
        "Runs the tunnel as root through one sudo-approved script, with a rule "
        + "granting passwordless sudo for that script alone."
    private static let backendKey = "PrivilegedBackend"

    /// Which backend the UI is operating on.
    ///
    /// Stored in UserDefaults rather than the app config: it selects how this
    /// machine is provisioned, not something a config file should carry between
    /// machines. Defaults to the daemon when the build could actually use it, and
    /// to the helper when it can't, so the initial selection is always installable.
    private var selectedBackend: PrivilegedInstaller.Backend {
        get {
            if currentCodeIdentity() == nil { return .rootHelper }
            let raw = UserDefaults.standard.string(forKey: Self.backendKey)
            return raw == "rootHelper" ? .rootHelper : .daemon
        }
        set {
            UserDefaults.standard.set(newValue == .rootHelper ? "rootHelper" : "daemon",
                                      forKey: Self.backendKey)
        }
    }

    @objc private func backendChanged() {
        selectedBackend = (backendPopup.indexOfSelectedItem == 1) ? .rootHelper : .daemon
        VPNRunner.shared.invalidateTransportCache()
        refreshHelperStatus()
    }

    // MARK: - Privileged helper

    /// Status can change outside the app — the user approving the background item
    /// in System Settings is the common case — so poll while the window is open.
    private func startHelperPolling() {
        refreshHelperStatus()
        guard helperTimer == nil else { return }
        helperTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshHelperStatus()
        }
    }

    func stopHelperPolling() {
        helperTimer?.invalidate()
        helperTimer = nil
    }

    /// The version line, in one shape for every state: what this build demands,
    /// and what is actually installed.
    ///
    /// Composed rather than written out per state. Six bespoke sentences made the
    /// reader re-parse the line each time it changed, and left it blank when
    /// nothing was installed — which reads like something failed to load. A fixed
    /// "required X · installed Y" always has the two numbers in the same place,
    /// and a test override simply annotates the number it actually affects.
    private func versionDetail(_ status: SMAppService.Status,
                               _ compat: PrivilegedClient.Compatibility?) -> String {
        let client = PrivilegedClient.shared
        // Prefer the figure the comparison actually used. Asking the client again
        // would normally give the same answer, but deriving it separately lets the
        // two halves of this line disagree — "required v1 · installed v1" next to
        // an "Update required" light.
        let requiredVersion: Int
        if case .outdated(_, let expected) = compat { requiredVersion = expected }
        else { requiredVersion = client.expectedProtocolVersion }

        var required = "v\(requiredVersion)"
        if client.expectedVersionIsOverridden { required += " (test override)" }

        let installed: String
        switch status {
        case .notRegistered:
            installed = "none"
        case .notFound:
            // Kept short: with an override appended, the longer phrasing overran
            // the single fixed-height line and truncated.
            installed = "none (unsigned build)"
        case .requiresApproval:
            // Reading the version means reaching the daemon, which macOS will not
            // allow until the background item is approved.
            installed = "unknown until approved"
        default:
            switch compat {
            case .current(let v), .outdated(let v, _): installed = "v\(v)"
            case .unreachable:                         installed = "no reply from daemon"
            case nil:                                  installed = "unknown"
            }
        }
        return "Protocol: required \(required) · installed \(installed)"
    }

    /// Rows for the SMAppService daemon backend.
    private func refreshDaemonRows() {
        helperHint.stringValue = Self.daemonExplanation
        let client = PrivilegedClient.shared
        // effectiveStatus, not status: a never-registered identifier reports .notFound,
        // which the default branch below explains as "unavailable in this build" and
        // disables Install for. That is right for an unsigned build and wrong for a
        // first install.
        let status = client.effectiveStatus
        // Probed once per refresh: it is an XPC round trip, and both the status
        // switch below and the version line need the answer.
        let compat: PrivilegedClient.Compatibility? =
            (status == .enabled) ? client.daemonCompatibility() : nil

        // Step 1 (installLight)  — is the daemon installed, and can this build talk to it?
        // Step 2 (approvalLight) — has macOS been told to allow it to run?
        //
        // Consecutive phases of one status, in this order. register() is what
        // creates the Login Items entry, so step 2 cannot be attempted until step 1
        // is done, and step 1 goes green as soon as registration succeeds.
        //
        // The version only becomes knowable once step 2 is satisfied, because
        // reading it means reaching the daemon over XPC — so step 1 reports a bare
        // "Installed" until then, and fills in the version afterwards.
        //
        // The Login Items button stays visible in every daemon state, rather than only
        // while approval is outstanding. macOS can switch a background item off
        // without the app being told — that is precisely how a working daemon here
        // ended up refusing to re-register with "Operation not permitted" — so the
        // route to the toggle must not depend on the app having correctly noticed.
        // It also stops the row's controls appearing and disappearing as the status
        // changes, which moved the layout around.
        helperApprovalButton.isHidden = false
        switch status {
        case .notRegistered:
            set(installLight, .tertiaryLabelColor)
            installText.stringValue = "Not installed"
            installText.textColor = .secondaryLabelColor
            helperInstallButton.title = "Install"
            helperInstallButton.isEnabled = true
            helperRemoveButton.isEnabled = false

            set(approvalLight, .tertiaryLabelColor)
            approvalText.stringValue = "Awaiting installation"
            approvalText.textColor = .secondaryLabelColor

        case .requiresApproval:
            // Installation genuinely succeeded; only the toggle is outstanding.
            set(installLight, .systemGreen)
            installText.stringValue = "Installed"
            installText.textColor = .labelColor
            helperInstallButton.title = "Install"
            helperInstallButton.isEnabled = false
            // Remove stays live: the only way to back out from inside the app.
            helperRemoveButton.isEnabled = true

            set(approvalLight, .systemOrange)
            approvalText.stringValue = "Waiting for your approval"
            approvalText.textColor = .labelColor

        case .enabled:
            helperRemoveButton.isEnabled = true

            switch compat ?? .unreachable {
            case .current:
                set(installLight, .systemGreen)
                installText.stringValue = "Installed"
                installText.textColor = .labelColor
                // The daemon protocol being current says nothing about the
                // root-owned support files it executes, and those do not update
                // when the app does. Offer the sync here or it is unreachable:
                // installDaemonBackend() checks for drift, but with the button
                // disabled there is no way to reach it — which is exactly how a
                // stale route-wrapper.sh kept running with no way to replace it
                // short of switching methods and reinstalling.
                let stale = !PrivilegedInstaller.supportFilesMatchBundle()
                helperInstallButton.title = stale ? "Update" : "Install"
                helperInstallButton.isEnabled = stale

                set(approvalLight, .systemGreen)
                approvalText.stringValue = "Allowed and running"
                approvalText.textColor = .labelColor

            case .outdated:
                // Amber on step 1, because the fault is the helper, not the
                // permission: it is allowed to run and is running. Connects are
                // falling back to sudo until it is replaced.
                set(installLight, .systemOrange)
                installText.stringValue = "Update required"
                installText.textColor = .labelColor
                // "Update" rather than "Reinstall": it mirrors the status word, and
                // re-registering really does swap in the newer bundled daemon.
                helperInstallButton.title = "Update"
                helperInstallButton.isEnabled = true

                set(approvalLight, .systemGreen)
                approvalText.stringValue = "Allowed and running"
                approvalText.textColor = .labelColor

            case .unreachable:
                set(installLight, .systemGreen)
                installText.stringValue = "Installed"
                installText.textColor = .labelColor
                helperInstallButton.title = "Reinstall"
                helperInstallButton.isEnabled = true

                set(approvalLight, .systemOrange)
                approvalText.stringValue = "Allowed, not responding"
                approvalText.textColor = .labelColor
            }

        default:   // .notFound — no bundled plist, or this build is not signed
            set(installLight, .tertiaryLabelColor)
            installText.stringValue = "Unavailable in this build"
            installText.textColor = .secondaryLabelColor
            helperInstallButton.title = "Install"
            helperInstallButton.isEnabled = false
            helperRemoveButton.isEnabled = false

            set(approvalLight, .tertiaryLabelColor)
            approvalText.stringValue = "Unavailable"
            approvalText.textColor = .secondaryLabelColor
        }

        // Drift in the support files is reported here too, because it is the reason
        // the button above became actionable and the protocol line alone wouldn't
        // explain why an otherwise healthy daemon has an Update offered.
        let filesStale = status == .enabled && !PrivilegedInstaller.supportFilesMatchBundle()
        helperVersionHint.stringValue = versionDetail(status, compat)
            + (filesStale ? " · support files differ from this build" : "")
        // Orange for an override (an artificial state that silently forces the sudo
        // fallback) or for drift (something is running that isn't what shipped).
        helperVersionHint.textColor =
            (client.expectedVersionIsOverridden || filesStale) ? .systemOrange : .secondaryLabelColor

    }

    /// Rows for the sudo root-helper backend.
    ///
    /// Same two-row shape, different meanings. Row 1 is whether the helper binary
    /// is installed; row 2 is whether the NOPASSWD sudoers rule authorises it.
    /// `helperUsable` is the authoritative test because it runs `sudo -n helper
    /// version`, which proves the file, the grant and the version together — the
    /// separate file checks only exist to explain *which* half is missing.
    private func refreshRootHelperRows() {
        helperHint.stringValue = Self.helperExplanation
        // Deliberately the one place this button stays hidden. In the daemon rows it is
        // always shown, because macOS can flip a background item off without telling
        // the app. This backend has no background item at all — its authorisation is a
        // sudoers rule — so Login Items would open on nothing relevant. That is a
        // different situation from "already allowed", which is what always-show exists
        // to cover.
        let st = PrivilegedInstaller.state()
        helperApprovalButton.isHidden = true

        if !st.canProvision {
            set(installLight, .tertiaryLabelColor)
            installText.stringValue = "Unavailable in this build"
            installText.textColor = .secondaryLabelColor
            helperInstallButton.title = "Install"
            helperInstallButton.isEnabled = false
            helperRemoveButton.isEnabled = st.helperPresent
            set(approvalLight, .tertiaryLabelColor)
            approvalText.stringValue = "Unavailable"
            approvalText.textColor = .secondaryLabelColor
            helperVersionHint.stringValue = "This build has no bundled support files. Rebuild with build-app.sh."
            helperVersionHint.textColor = .secondaryLabelColor
            return
        }

        if st.helperUsable {
            set(installLight, .systemGreen)
            installText.stringValue = "Installed"
            installText.textColor = .labelColor
            // Offer a refresh when the installed copies have drifted from the
            // bundle, since those copies are what actually run.
            let stale = !st.supportFilesUpToDate
            helperInstallButton.title = stale ? "Update" : "Install"
            helperInstallButton.isEnabled = stale
            helperRemoveButton.isEnabled = true

            set(approvalLight, .systemGreen)
            approvalText.stringValue = "Passwordless sudo rule active"
            approvalText.textColor = .labelColor
            helperVersionHint.stringValue = stale
                ? "Support files differ from this build — update to apply them."
                : "Support files match this build."
            helperVersionHint.textColor = stale ? .systemOrange : .secondaryLabelColor
            return
        }

        // Not usable. Say which half is missing rather than just "not working".
        if st.helperPresent {
            set(installLight, .systemGreen)
            installText.stringValue = "Installed"
            installText.textColor = .labelColor
            helperInstallButton.title = "Repair"
            helperInstallButton.isEnabled = true
            helperRemoveButton.isEnabled = true

            set(approvalLight, .systemOrange)
            approvalText.stringValue = st.sudoersPresent
                ? "Sudo rule present but not working"
                : "No sudo rule — password needed"
            approvalText.textColor = .labelColor
            helperVersionHint.stringValue = st.sudoersPresent
                ? "The rule exists but `sudo -n` was refused. Repair reinstalls it."
                : "Repair adds a rule allowing only this helper, without a password."
        } else {
            set(installLight, .tertiaryLabelColor)
            installText.stringValue = "Not installed"
            installText.textColor = .secondaryLabelColor
            helperInstallButton.title = "Install"
            helperInstallButton.isEnabled = true
            helperRemoveButton.isEnabled = st.sudoersPresent

            set(approvalLight, .tertiaryLabelColor)
            approvalText.stringValue = "Awaiting installation"
            approvalText.textColor = .secondaryLabelColor
            helperVersionHint.stringValue = "Installing asks for your password once, then never again."
        }
        helperVersionHint.textColor = .secondaryLabelColor
    }

    private func refreshHelperStatus() {
        guard isViewLoaded else { return }
        // Keep the popup showing the stored choice: it can be changed from either
        // side (here, or by a build that cannot use the daemon at all).
        backendPopup.selectItem(at: selectedBackend == .rootHelper ? 1 : 0)

        switch selectedBackend {
        case .daemon:     refreshDaemonRows()
        case .rootHelper: refreshRootHelperRows()
        }
        // Polled alongside the helper so a change made in System Settings appears here
        // rather than only after the window is reopened.
        refreshLaunchAtLogin()

        // Say which privileged path connects will actually take, so the effect of
        // installing (or not) is visible rather than implied.
        let route: String
        switch VPNRunner.shared.privilegedTransport() {
        case .daemon:          route = "connects use the privileged daemon"
        case .sudoHelper:      route = "connects use the sudoers helper"
        case .interactiveSudo: route = "connects will prompt for sudo"
        }
        helperRouteHint.stringValue = "Currently: \(route)."

    }

    @objc private func installHelper() {
        switch selectedBackend {
        case .daemon:     installDaemonBackend()
        case .rootHelper: installRootHelperBackend()
        }
    }

    /// Run a privileged operation off the main thread, then put the window back.
    ///
    /// Two problems this solves, both caused by doing it inline. The authentication
    /// panel belongs to another process while our `waitUntilExit` blocks the main
    /// thread, so this window cannot redraw and looks frozen. And when the panel
    /// dismisses, focus does not return to an accessory app by itself — the window
    /// is left behind whatever was frontmost, which reads as it having closed.
    private func runPrivileged(_ failureTitle: String,
                               _ work: @escaping () throws -> Void) {
        // Whether to take focus back afterwards. Only if we had it: a user who
        // deliberately switched away during the panel shouldn't be yanked back.
        let wasActive = NSApp.isActive
        helperInstallButton.isEnabled = false
        helperRemoveButton.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                try work()
            } catch PrivilegedInstaller.Failure.cancelled {
                failure = nil          // a normal choice, not an error
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                PrivilegedClient.shared.invalidateVersionCache()
                VPNRunner.shared.invalidateTransportCache()
                if wasActive, let w = self.view.window {
                    NSApp.activate()
                    w.makeKeyAndOrderFront(nil)
                }
                self.refreshHelperStatus()   // also restores the button states
                if let f = failure { self.warn(failureTitle, f) }
            }
        }
    }

    private func installDaemonBackend() {
        // The daemon runs the root-owned support files, not the bundled ones, and
        // they don't update when the app does. Refresh them first when they've
        // drifted — otherwise a fixed script sits in the bundle while the old one
        // keeps running. Skipped when they already match, so there's no
        // authentication panel for a no-op.
        let needsSupportFiles = !PrivilegedInstaller.state().supportFilesUpToDate
        // Only touch the registration when the daemon isn't already installed and
        // speaking our protocol. When just the support files drifted — the ordinary
        // case after a build that changed route-wrapper.sh or vpnc-script — copying
        // them IS the whole job.
        //
        // Re-registering regardless was not merely redundant, it could leave things
        // worse than it found them: unregister() succeeds, then register() is refused
        // because the background item's disposition is `disabled` (macOS reports that
        // as a flat "Operation not permitted"), and a working daemon has become no
        // daemon at all. Never give up a good registration we didn't need to replace.
        let daemonAlreadyCurrent = PrivilegedClient.shared.isUsable()
        runPrivileged("Couldn't install the privileged daemon") {
            if needsSupportFiles {
                try PrivilegedInstaller.install(.daemon)
            }
            // Replacing a stale daemon means tearing the old registration down and
            // putting it back — and waiting for launchd in between, which is what
            // reregister() exists to do.
            if !daemonAlreadyCurrent {
                try PrivilegedClient.shared.reregister()
            }
        }
    }

    private func installRootHelperBackend() {
        runPrivileged("Couldn't install the root helper") {
            try PrivilegedInstaller.install(.rootHelper)
        }
    }

    private func warn(_ title: String, _ detail: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = detail
        if let w = view.window {
            a.beginSheetModal(for: w)
        } else {
            a.runModal()
        }
    }

    @objc private func removeHelper() {
        switch selectedBackend {
        case .daemon:
            runPrivileged("Couldn't remove the privileged daemon") {
                try PrivilegedClient.shared.unregister()
            }
        case .rootHelper:
            runPrivileged("Couldn't remove the root helper") {
                // Withdraws the sudo grant and the helper but keeps the support
                // files: the daemon backend needs those, so removing them would
                // break anyone switching methods.
                try PrivilegedInstaller.removeRootHelper()
            }
        }
    }

    /// Register or unregister the app as a login item.
    ///
    /// The checkbox is not the source of truth — the system is. So whatever happens
    /// here, the last thing we do is re-read the status and show that, rather than
    /// leaving the checkbox displaying what the user asked for after a failure.
    @objc private func toggleLaunchAtLogin() {
        let want = (launchAtLogin.state == .on)
        do {
            if want { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            warn(want ? "Couldn't turn on launch at login"
                      : "Couldn't turn off launch at login",
                 error.localizedDescription)
        }
        refreshLaunchAtLogin()
    }

    /// Mirror the system's view of the login item.
    ///
    /// Also called from the status poll, so flipping the switch in System Settings is
    /// reflected here without reopening the window.
    private func refreshLaunchAtLogin() {
        guard launchAtLogin != nil else { return }
        let status = SMAppService.mainApp.status
        // .requiresApproval means registered but not yet allowed to run, so it counts
        // as on: unregistering would be the wrong response to "waiting for you".
        launchAtLogin.state = (status == .enabled || status == .requiresApproval) ? .on : .off
        // Said in the tooltip rather than the title on purpose. The label sizes this
        // grid row, so making the text longer when approval is pending would widen the
        // whole pane and shift the layout every time the status changed.
        launchAtLogin.toolTip = status == .requiresApproval
            ? "Registered, but macOS is still waiting for you to allow it — "
              + "use Open Login Items… below"
            : "System Settings > General > Login Items & Extensions"
    }

    @objc private func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    override var focusChain: [NSView] {
        // Order follows the visible layout, so tabbing goes down the pane rather than
        // jumping about — which is why launchAtLogin leads now that it is the top row.
        [launchAtLogin, activeProfilePopup, showName, autoReconnect,
         maxRetries, retryDelay, openconnectField]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Profiles added or renamed in the Profiles pane have to show up here
        // without the window being reopened.
        NotificationCenter.default.addObserver(
            self, selector: #selector(configDidChange),
            name: ConfigStore.didChangeNotification, object: nil)
    }

    @objc private func configDidChange() {
        guard isViewLoaded else { return }
        reloadProfileList()
        // The menu bar can now toggle this too, so the checkbox has to follow or
        // the two would disagree while the window is open. Checkboxes only: text
        // fields are deliberately left alone, since reloading one would discard
        // whatever the user is part-way through typing.
        let showing = ConfigStore.shared.config.general.menubar.showEndpointName
        let wanted: NSControl.StateValue = showing ? .on : .off
        if showName.state != wanted {
            loading = true
            showName.state = wanted
            loading = false
        }
    }

    /// Rebuild only the profile popup, so a change elsewhere can't stomp on a
    /// field the user is currently editing.
    private func reloadProfileList() {
        let c = ConfigStore.shared.config
        loading = true
        activeProfilePopup.removeAllItems()
        profileIDsInPopup = []
        let titles = Self.popupTitles(for: c.profiles)
        for (i, p) in c.profiles.enumerated() {
            activeProfilePopup.addItem(withTitle: titles[i])
            profileIDsInPopup.append(p.id)
        }
        if c.profiles.isEmpty {
            activeProfilePopup.addItem(withTitle: "No profiles")
        }
        activeProfilePopup.isEnabled = !c.profiles.isEmpty
        if let idx = profileIDsInPopup.firstIndex(of: c.activeProfileID) {
            activeProfilePopup.selectItem(at: idx)
        }
        loading = false
    }

    /// Menu titles for the popup.
    ///
    /// Nothing stops two profiles sharing a name — importing the same file twice
    /// is the obvious way in — and two identical menu entries make choosing one
    /// a coin flip. A shared name is qualified with its primary host, and
    /// anything still ambiguous after that gets an ordinal.
    static func popupTitles(for profiles: [Profile]) -> [String] {
        var nameCounts: [String: Int] = [:]
        for p in profiles { nameCounts[p.name, default: 0] += 1 }

        var titles: [String] = profiles.map { p in
            guard (nameCounts[p.name] ?? 0) > 1 else { return p.name }
            if let host = p.endpoints.first?.host, !host.isEmpty { return "\(p.name) — \(host)" }
            return p.name
        }

        let qualified = titles
        var dupes: [String: Int] = [:]
        for t in qualified { dupes[t, default: 0] += 1 }
        var used: [String: Int] = [:]
        for i in titles.indices where (dupes[qualified[i]] ?? 0) > 1 {
            used[qualified[i], default: 0] += 1
            titles[i] = "\(qualified[i]) (\(used[qualified[i]]!))"
        }
        return titles
    }

    func reload() {
        loadViewIfNeeded()
        loading = true
        let c = ConfigStore.shared.config
        showName.state = c.general.menubar.showEndpointName ? .on : .off
        autoReconnect.state = c.general.autoReconnect.enabled ? .on : .off
        maxRetries.stringValue = String(c.general.autoReconnect.maxRetries)
        retryDelay.stringValue = String(c.general.autoReconnect.retryDelaySeconds)
        openconnectField.stringValue = c.general.openconnectPath
        detectedLabel.stringValue = "Detected: \(VPNRunner.shared.openconnectPath())"
        loading = false
        reloadProfileList()
        startHelperPolling()
    }

    /// Modeless: any control change writes through immediately.
    @objc private func apply() {
        guard !loading else { return }
        ConfigStore.shared.update { c in
            c.general.menubar.showEndpointName = (showName.state == .on)
            c.general.autoReconnect.enabled = (autoReconnect.state == .on)
            c.general.autoReconnect.maxRetries = Int(maxRetries.stringValue) ?? 5
            c.general.autoReconnect.retryDelaySeconds = Int(retryDelay.stringValue) ?? 5
            c.general.openconnectPath = openconnectField.stringValue.trimmingCharacters(in: .whitespaces)
            let sel = activeProfilePopup.indexOfSelectedItem
            if sel >= 0 && sel < profileIDsInPopup.count { c.activeProfileID = profileIDsInPopup[sel] }
        }
        detectedLabel.stringValue = "Detected: \(VPNRunner.shared.openconnectPath())"
        notifyAppDelegate()
    }

    // Text fields commit when editing ends (tab away, click out, or Return).
    func controlTextDidEndEditing(_ obj: Notification) { apply() }
}

// ── Profiles pane ────────────────────────────────────────────────────────────
// Terminal ▸ Settings ▸ Profiles layout: the profile list on the left with
// + / − / duplicate / Import beneath it, the selected profile's form on the
// right. Modeless — edits persist as they are made.
final class ProfilesPane: SettingsPane, NSTableViewDataSource, NSTableViewDelegate,
                          NSTextFieldDelegate, NSTabViewDelegate {
    override var naturalWidth: CGFloat { 700 }
    override var minimumWidth: CGFloat { 620 }
    override var isResizablePane: Bool { true }

    private let sidebarWidth: CGFloat = 170

    private var profileTable: NSTableView!
    private var removeProfileButton: NSButton!
    private var innerTabs: NSTabView!
    private var detailPlaceholder: NSView!
    private var detailControls: [NSControl] = []
    private var endpointButtons: [NSControl] = []
    private var exceptionButtons: [NSControl] = []
    private var protocolPopup: NSPopUpButton!
    private var authgroupField: NSTextField!
    private var authgroupHint: NSTextField!
    private var csdCheck: NSButton!
    private var lanAutoCheck: NSButton!
    private var exceptionTable: NSTableView!
    private var endpointTable: NSTableView!

    private let protocols = ["anyconnect", "nc", "gp", "pulse", "f5", "fortinet", "array"]

    /// True when `currentIndex` names a real profile.
    ///
    /// With zero profiles `currentIndex` is -1, and a bare
    /// `currentIndex < working.count` check *passes* for -1 (-1 < 0) — which
    /// then indexes `working[-1]` and traps. Every bounds check goes through
    /// here so that can't be got wrong again.
    private var hasSelection: Bool { currentIndex >= 0 && currentIndex < working.count }


    private var working: [Profile] = []
    private var currentIndex = 0
    private var loading = false

    override func content() -> NSView {
        let sidebar = buildSidebar()
        let detail = buildDetail()

        let split = NSStackView(views: [sidebar, detail])
        split.orientation = .horizontal
        split.alignment = .top
        split.spacing = 16
        split.distribution = .fill
        split.translatesAutoresizingMaskIntoConstraints = false

        let eq = sidebar.heightAnchor.constraint(equalTo: detail.heightAnchor)
        eq.priority = .defaultHigh
        eq.isActive = true

        let body = column([split], spacing: 16)
        split.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        return body
    }

    /// The profile list leads, as it does in Terminal, so arrow keys move
    /// between profiles the moment the pane opens.
    ///
    /// Only on-screen controls are chained: NSTabView detaches the views of an
    /// unselected inner tab, and pointing `nextKeyView` at a detached view
    /// breaks the loop. `applyFocus` is re-run when the inner tab changes.
    override var focusChain: [NSView] {
        let candidates: [NSView] = [profileTable, protocolPopup, authgroupField,
                                    csdCheck, lanAutoCheck, exceptionTable, endpointTable]
        return candidates.filter { $0 === profileTable || $0.window != nil }
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard tabView === innerTabs, let window = view.window else { return }
        applyFocus(in: window)
    }

    private func buildSidebar() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        profileTable = NSTableView()
        profileTable.identifier = NSUserInterfaceItemIdentifier("profileList")
        profileTable.headerView = nil
        profileTable.rowHeight = 22
        profileTable.allowsEmptySelection = false
        let col = NSTableColumn(identifier: .init("name"))
        col.resizingMask = .autoresizingMask
        profileTable.addTableColumn(col)
        profileTable.dataSource = self
        profileTable.delegate = self
        profileTable.target = self
        profileTable.doubleAction = #selector(renameSelectedProfile)
        scroll.documentView = profileTable

        removeProfileButton = iconButton("minus", #selector(delProfile),
                                        tooltip: "Delete selected profile")
        let buttons = NSStackView(views: [
            iconButton("plus", #selector(newProfile), tooltip: "New profile"),
            removeProfileButton,
            iconButton("ellipsis", #selector(showActionsMenu(_:)), tooltip: "More actions"),
        ])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: sidebarWidth),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        return stack
    }

    /// The detail side, split across two inner tabs.
    ///
    /// Stacked in one column this form ran to roughly 500pt, which made the
    /// window taller than the content deserved. Terminal's Profiles pane does
    /// the same thing (Text / Window / Tab / Shell / …), and the settings
    /// guideline explicitly sanctions a nested NSTabView for a pane holding
    /// more than fits comfortably.
    private func buildDetail() -> NSView {
        protocolPopup = NSPopUpButton()
        protocolPopup.addItems(withTitles: protocols)
        protocolPopup.target = self
        protocolPopup.action = #selector(applyProfile)
        protocolPopup.translatesAutoresizingMaskIntoConstraints = false
        protocolPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true

        // A plain field, not a combo box. The list of groups is server-side state
        // that can change, so it is never cached — which left the dropdown empty
        // until you happened to fetch, and populated only sometimes afterwards.
        // An affordance that is usually empty is worse than no affordance: the
        // value is typed or chosen through the sheet, and the field just holds it.
        authgroupField = field(width: 180, id: "authgroup", delegate: self)
        authgroupField.placeholderString = "None"
        authgroupHint = hint("Default for this profile's endpoints. An endpoint can override it.",
                             width: kHintWidth, fixedLines: 1)

        csdCheck = check("Handle posture (CSD) checks", #selector(applyProfile))
        lanAutoCheck = check("My local network", #selector(applyProfile))
        let fetchButton = button("Choose…", #selector(fetchGroups), small: true)
        fetchButton.toolTip = "Ask a gateway which auth groups it advertises"

        // No "Name:" row. The name is edited inline in the list instead, the way
        // Terminal renames a profile — showing it in both places is redundant,
        // and it keeps this tab honestly about the gateway.
        let gatewayForm = form([
            [formLabel("Protocol:"), protocolPopup],
            [formLabel("Auth group:"), hrow([authgroupField, fetchButton])],
            [NSGridCell.emptyContentView, authgroupHint],
            [formLabel("Posture:"), csdCheck],
            [formLabel("Endpoints:"), buildEndpoints()],
        ])
        gatewayForm.row(at: 1).bottomPadding = -4
        gatewayForm.row(at: 4).yPlacement = .top

        // One concept, two controls. "LAN access" and "Exceptions" read as
        // unrelated settings, and "Exceptions" never said what they were exceptions
        // to — but both do the same thing: keep traffic off the tunnel. Naming the
        // shared idea, and making the second row "Also bypass", says how they relate.
        let routingForm = form([
            [formLabel("Bypass VPN:"), lanAutoCheck],
            [NSGridCell.emptyContentView,
             hint("Keeps other devices on your subnet reachable while connected.")],
            [formLabel("Also bypass:"), buildExceptions()],
        ])
        routingForm.row(at: 1).topPadding = -4
        routingForm.row(at: 2).topPadding = 10
        routingForm.row(at: 2).yPlacement = .top

        detailControls = [protocolPopup, authgroupField, fetchButton,
                          csdCheck, lanAutoCheck, endpointTable, exceptionTable]
            + endpointButtons + exceptionButtons

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.delegate = self
        tabs.addTabViewItem(innerTab("Gateway", gatewayForm))
        tabs.addTabViewItem(innerTab("Routing", routingForm))

        // An NSTabView reports nothing useful about its own size, so measure the
        // larger tab and add the chrome the tab strip actually takes.
        gatewayForm.layoutSubtreeIfNeeded()
        routingForm.layoutSubtreeIfNeeded()
        let g = gatewayForm.fittingSize, r = routingForm.fittingSize
        let contentW = max(g.width, r.width) + innerTabInset * 2
        let contentH = max(g.height, r.height) + innerTabInset * 2

        tabs.frame = NSRect(x: 0, y: 0, width: contentW + 40, height: contentH + 60)
        tabs.layoutSubtreeIfNeeded()
        var chromeW = tabs.frame.width - tabs.contentRect.width
        var chromeH = tabs.frame.height - tabs.contentRect.height
        // Fall back to measured-by-hand chrome if contentRect isn't resolved yet.
        if chromeW <= 0 || chromeW > 60 { chromeW = 14 }
        if chromeH <= 0 || chromeH > 90 { chromeH = 40 }
        NSLayoutConstraint.activate([
            tabs.widthAnchor.constraint(equalToConstant: (contentW + chromeW).rounded(.up)),
            tabs.heightAnchor.constraint(equalToConstant: (contentH + chromeH).rounded(.up)),
        ])
        innerTabs = tabs

        // With no profile there is nothing for the form to edit, and a fully
        // greyed-out form reads as a broken window. Show a placeholder in its
        // place instead — the standard master-detail answer, and on a fresh
        // install it doubles as the way in.
        let placeholder = buildDetailPlaceholder()
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabs)
        container.addSubview(placeholder)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: container.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabs.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])
        detailPlaceholder = placeholder
        return container
    }

    private func buildDetailPlaceholder() -> NSView {
        let title = NSTextField(labelWithString: "No Profiles")
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.alignment = .center

        let body = NSTextField(labelWithString:
            "Add a gateway with +, or bring in a configuration you already have.")
        body.font = .systemFont(ofSize: 11)
        body.textColor = .tertiaryLabelColor
        body.alignment = .center

        let actions = NSStackView(views: [
            button("Auto-detect…", #selector(autoDetect)),
            button("Import from File…", #selector(importFromFile)),
        ])
        actions.orientation = .horizontal
        actions.spacing = 8

        let stack = NSStackView(views: [title, body, actions])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private let innerTabInset: CGFloat = 14

    private func innerTab(_ label: String, _ content: NSView) -> NSTabViewItem {
        let holder = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: holder.topAnchor, constant: innerTabInset),
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: innerTabInset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor,
                                              constant: -innerTabInset),
            content.bottomAnchor.constraint(lessThanOrEqualTo: holder.bottomAnchor,
                                            constant: -innerTabInset),
        ])
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = holder
        return item
    }

    /// Show the form, or the placeholder when there is no profile to edit.
    private func setDetailEnabled(_ on: Bool) {
        innerTabs?.isHidden = !on
        detailPlaceholder?.isHidden = on
        for c in detailControls { c.isEnabled = on }
    }

    /// Routes kept off the tunnel, as an editable list rather than one
    /// comma-separated field. Any CIDR works here, including public ranges —
    /// the route wrapper simply points it at the physical gateway.
    private func buildExceptions() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        exceptionTable = NSTableView()
        exceptionTable.identifier = NSUserInterfaceItemIdentifier("exceptionList")
        exceptionTable.rowHeight = 20
        exceptionTable.headerView = nil
        // No striping: on a short list the empty-row stripes read as content.
        exceptionTable.usesAlternatingRowBackgroundColors = false
        let col = NSTableColumn(identifier: .init("exception"))
        col.resizingMask = .autoresizingMask
        exceptionTable.addTableColumn(col)
        exceptionTable.dataSource = self
        exceptionTable.delegate = self
        scroll.documentView = exceptionTable

        exceptionButtons = [
            iconButton("plus", #selector(addException), tooltip: "Add an excluded route"),
            iconButton("minus", #selector(removeException), tooltip: "Remove selected route"),
        ]
        let buttons = NSStackView(views: exceptionButtons.map { $0 as NSView }
            + [hint("IPv4 CIDR, address, or host name — public ranges allowed")])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        // State the snapshot caveat where it will actually be read.
        let caveat = hint("Host names resolve at connect time; later address changes aren't tracked.")
        caveat.lineBreakMode = .byWordWrapping

        let stack = NSStackView(views: [scroll, buttons, caveat])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Matched to the endpoint list. The inner tab view is sized to its
            // tallest tab regardless, so a short list here just left dead space;
            // spending it on visible rows is more use than padding.
            scroll.heightAnchor.constraint(equalToConstant: 150),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])
        return stack
    }

    private func buildEndpoints() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        endpointTable = NSTableView()
        endpointTable.identifier = NSUserInterfaceItemIdentifier("endpointList")
        endpointTable.rowHeight = 20
        // The default here is 17pt, which across five columns spends 68pt on gaps
        // — enough on its own to push the last column outside the clip view. 6pt
        // still reads as separate columns and returns that space to the content.
        endpointTable.intercellSpacing = NSSize(width: 6, height: 2)
        endpointTable.usesAlternatingRowBackgroundColors = true
        // "Auth group" earns its place because an endpoint-level override is
        // otherwise invisible state: the sheet can write one, and nothing else on
        // the form would show it.
        //
        // Widths sum to 484; with 6pt intercell spacing x4 that is 508, inside the
        // 518pt the 520pt container leaves after its bezel. Measured rather than
        // estimated — the default 17pt spacing made the real requirement 538 and
        // silently pushed the last column out of view. Squeezing all five into the
        // old 444 truncated hostnames, the one column that has to stay readable.
        for (idc, title, w, minW) in [("star", "★", 26, 26), ("key", "Key", 90, 70),
                                      ("label", "Label", 116, 84), ("host", "Host", 168, 120),
                                      ("authgroup", "Auth group", 84, 70)] {
            let c = NSTableColumn(identifier: .init(idc))
            c.title = title
            c.width = CGFloat(w)
            c.minWidth = CGFloat(minW)
            endpointTable.addTableColumn(c)
        }
        endpointTable.dataSource = self
        endpointTable.delegate = self
        scroll.documentView = endpointTable

        endpointButtons = [
            iconButton("plus", #selector(addRow), tooltip: "Add endpoint"),
            iconButton("minus", #selector(removeRow), tooltip: "Remove selected endpoint"),
        ]
        let buttons = NSStackView(views: endpointButtons.map { $0 as NSView }
            + [hint("★ marks a favourite, shown at the top of the menu")])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])
        return stack
    }

    // MARK: - Model

    func reload() {
        loadViewIfNeeded()
        loading = true
        working = ConfigStore.shared.config.profiles
        currentIndex = working.isEmpty
            ? -1
            : (working.firstIndex { $0.id == ConfigStore.shared.config.activeProfileID } ?? 0)
        loading = false
        refreshProfileList()
        loadProfileIntoFields()
    }

    /// Repopulate the sidebar and re-select `currentIndex`.
    ///
    /// The whole span is flagged as `loading`, not just the selection call:
    /// `reloadData()` on a table with `allowsEmptySelection = false` makes
    /// AppKit select row 0 itself, and that notification is indistinguishable
    /// from the user clicking a different profile. Left unguarded it reset
    /// `currentIndex` to 0 and persisted the previous profile's field values
    /// over the wrong record.
    private func refreshProfileList() {
        loading = true
        profileTable.reloadData()
        // At least one profile has to remain, so show that in the control rather
        // than ignoring the click.
        removeProfileButton?.isEnabled = !working.isEmpty
        if hasSelection {
            profileTable.selectRowIndexes(IndexSet(integer: currentIndex), byExtendingSelection: false)
        }
        loading = false
    }

    private func loadProfileIntoFields() {
        guard hasSelection else {
            // Nothing selected, which now happens for real: zero profiles is a
            // valid state. Blank the form and lock it rather than leaving the
            // previous profile's values sitting there looking editable.
            loading = true
            authgroupField.stringValue = ""
            csdCheck.state = .off
            lanAutoCheck.state = .off
            exceptionTable.reloadData()
            endpointTable.reloadData()
            loading = false
            setDetailEnabled(false)
            return
        }
        setDetailEnabled(true)
        loading = true
        let p = working[currentIndex]
        if let i = protocols.firstIndex(of: p.protocolName) { protocolPopup.selectItem(at: i) }
        authgroupField.stringValue = p.authgroup
        csdCheck.state = p.csdEnabled ? .on : .off
        lanAutoCheck.state = p.lanAccess.autoAddLocalSubnet ? .on : .off
        exceptionTable.reloadData()
        endpointTable.reloadData()
        loading = false
    }

    private func captureFields() {
        guard hasSelection else { return }
        working[currentIndex].protocolName = protocolPopup.titleOfSelectedItem ?? "anyconnect"
        working[currentIndex].authgroup = authgroupField.stringValue.trimmingCharacters(in: .whitespaces)
        working[currentIndex].csdEnabled = (csdCheck.state == .on)
        working[currentIndex].lanAccess.autoAddLocalSubnet = (lanAutoCheck.state == .on)
        // Exception routes are edited directly in the table, so there's no
        // field to read back here.
    }

    /// Modeless: capture the form and persist. Endpoints with no key or host are
    /// kept in the working copy (so a half-typed row isn't destroyed) but not
    /// written to disk.
    @objc private func applyProfile() {
        guard !loading else { return }
        captureFields()
        persist()
    }

    private func persist() {
        var out = working
        for i in out.indices {
            out[i].endpoints = out[i].endpoints.filter { !$0.key.isEmpty && !$0.host.isEmpty }
            // A freshly added row is blank until typed into; don't write those.
            out[i].lanAccess.manualExceptionRoutes =
                out[i].lanAccess.manualExceptionRoutes.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        let activeID = out[safe: currentIndex]?.id ?? ConfigStore.shared.config.activeProfileID
        ConfigStore.shared.update { c in
            c.profiles = out
            if !c.profiles.contains(where: { $0.id == c.activeProfileID }) {
                c.activeProfileID = activeID
            }
        }
        notifyAppDelegate()
    }

    // MARK: - Profile actions

    /// Keep a generated name distinct from the ones already present. Importing
    /// the same file twice otherwise leaves two profiles called the same thing.
    private func uniqueProfileName(_ base: String) -> String {
        let taken = Set(working.map { $0.name })
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    @objc private func newProfile() {
        captureFields()
        var p = Profile(); p.name = uniqueProfileName("New Profile")
        working.append(p); currentIndex = working.count - 1
        refreshProfileList(); loadProfileIntoFields(); persist()
    }

    @objc private func dupProfile() {
        captureFields()
        guard hasSelection else { return }
        var p = working[currentIndex]; p.id = UUID().uuidString
        p.name = uniqueProfileName(p.name + " copy")
        working.append(p); currentIndex = working.count - 1
        refreshProfileList(); loadProfileIntoFields(); persist()
    }

    /// Deleting a profile is confirmed because this pane is modeless: there is no
    /// Cancel to back out of, `persist()` writes straight to disk, and a profile
    /// can hold a lot of work (endpoints, favourites, gateway settings). The one
    /// exception is a profile that is still untouched — nagging about discarding
    /// nothing is just friction.
    @objc private func delProfile() {
        guard hasSelection else { return }
        let profile = working[currentIndex]

        let isUntouched = profile.endpoints.isEmpty
            && profile.authgroup.isEmpty
            && profile.lanAccess.manualExceptionRoutes.isEmpty
            && (profile.name == "New Profile" || profile.name.isEmpty)
        if isUntouched {
            performDeleteProfile()
            return
        }

        let count = profile.endpoints.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the profile “\(profile.name)”?"
        alert.informativeText = count == 0
            ? "Its gateway settings will be removed. This can't be undone."
            : "Its \(count) endpoint\(count == 1 ? "" : "s") and gateway settings will be "
              + "removed. This can't be undone."
        let deleteButton = alert.addButton(withTitle: "Delete")
        let cancelButton = alert.addButton(withTitle: "Cancel")
        deleteButton.hasDestructiveAction = true
        // Deliberately leave Return bound to nothing: the HIG wants the safe
        // choice to be the default for a destructive action, and NSAlert
        // reassigns Return to its own first button if we try to hand it to
        // Cancel. So Escape cancels, and deleting takes an actual click.
        deleteButton.keyEquivalent = ""
        cancelButton.keyEquivalent = "\u{1b}"

        // A sheet on the settings window rather than an app-modal dialog.
        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.performDeleteProfile() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            performDeleteProfile()
        }
    }

    private func performDeleteProfile() {
        guard hasSelection else { return }
        working.remove(at: currentIndex)
        currentIndex = working.isEmpty ? -1 : max(0, currentIndex - 1)
        refreshProfileList(); loadProfileIntoFields(); persist()
    }

    /// The "⋯" menu under the profile list.
    @objc private func showActionsMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename Profile", action: #selector(renameSelectedProfile), keyEquivalent: "")
        menu.addItem(withTitle: "Duplicate Profile", action: #selector(dupProfile), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Auto-detect Configurations…", action: #selector(autoDetect), keyEquivalent: "")
        menu.addItem(withTitle: "Import from File…", action: #selector(importFromFile), keyEquivalent: "")
        for item in menu.items { item.target = self }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// Scan the well-known client-profile directories and let the user choose
    /// which of the configurations found should become a profile.
    @objc private func autoDetect() {
        let configs = ProfileImporter.detectConfigs()
        guard !configs.isEmpty else {
            let a = NSAlert()
            a.messageText = "No VPN configurations found"
            a.informativeText = "Looked in:\n" + ProfileImporter.searchPaths.joined(separator: "\n")
                + "\n\nUse “Import from File…” to pick a profile manually."
            a.runModal()
            return
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 25))
        for c in configs {
            popup.addItem(withTitle: "\(c.name)  (\(c.endpoints.count) endpoint\(c.endpoints.count == 1 ? "" : "s"))")
        }
        let a = NSAlert()
        a.messageText = "Import a detected configuration"
        a.informativeText = "Found \(configs.count) configuration file\(configs.count == 1 ? "" : "s")."
        a.accessoryView = popup
        a.addButton(withTitle: "Import")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let idx = popup.indexOfSelectedItem
        guard idx >= 0, idx < configs.count else { return }
        createProfile(from: configs[idx])
    }

    /// Let the user pick a profile file themselves.
    @objc private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.xml]
        // Naming the one format we parse is more use than a vague "supported
        // config" — it tells you what to go looking for. Revisit if a second
        // parser is ever added.
        panel.message = "Choose a VPN client profile to import.\n"
            + "Only Cisco AnyConnect / Secure Client profiles (.xml) are supported so far."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let cfg = ProfileImporter.parse(fileAt: url.path) else {
            let a = NSAlert()
            a.messageText = "Nothing to import"
            a.informativeText = "“\(url.lastPathComponent)” contained no <HostEntry> server entries.\n\n"
                + "The only format supported so far is Cisco AnyConnect / Secure Client "
                + "profile XML. Other client formats (.ovpn, .mobileconfig) aren't read yet — "
                + "you can add the gateway by hand with + instead."
            a.runModal()
            return
        }
        createProfile(from: cfg)
    }

    /// Turn a detected or user-chosen configuration into a new profile.
    private func createProfile(from cfg: DetectedConfig) {
        captureFields()
        var p = Profile()
        p.name = uniqueProfileName(cfg.name)
        var keys = Set<String>()
        for e in cfg.endpoints {
            let key = makeKey(from: e.label, existing: keys); keys.insert(key)
            p.endpoints.append(Endpoint(key: key, label: e.label, host: e.host, favorite: false))
        }
        working.append(p)
        currentIndex = working.count - 1
        refreshProfileList(); loadProfileIntoFields(); persist()

        let a = NSAlert()
        a.messageText = "Imported \(cfg.endpoints.count) endpoint\(cfg.endpoints.count == 1 ? "" : "s")"
        a.informativeText = "Created the profile “\(p.name)” from \(cfg.path).\n\n"
            + "Star the endpoints you want at the top of the menu."
        a.runModal()
    }

    @objc private func fetchGroups() {
        captureFields()
        guard hasSelection else { return }
        let profile = working[currentIndex]
        // Only endpoints with a host are worth offering: a half-typed row would
        // just produce a confusing failure inside the sheet.
        let usable = profile.endpoints.filter { !$0.host.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty else {
            let a = NSAlert()
            a.messageText = "Add an endpoint first"
            a.informativeText = "Auth groups come from a specific gateway, so there has to be "
                + "one to ask."
            a.runModal()
            return
        }

        let sheet = AuthGroupSheet(
            endpoints: usable,
            protocolName: profile.protocolName,
            csdWrapper: profile.csdEnabled ? profile.csdWrapper : "",
            currentValue: authgroupField.stringValue.trimmingCharacters(in: .whitespaces)
        ) { [weak self] choice in
            self?.applyAuthGroupChoice(choice)
        }
        presentAsSheet(sheet)
    }

    private func applyAuthGroupChoice(_ choice: AuthGroupSheet.Choice) {
        guard hasSelection else { return }
        switch choice.scope {
        case .profileDefault:
            authgroupField.stringValue = choice.group
            working[currentIndex].authgroup = choice.group
        case .endpointOnly:
            guard let i = working[currentIndex].endpoints
                .firstIndex(where: { $0.key == choice.endpointKey }) else { return }
            working[currentIndex].endpoints[i].authgroup = choice.group
            endpointTable.reloadData()
        }
        applyProfile()
    }

    // MARK: - Endpoint actions

    @objc private func toggleStar(_ sender: NSButton) {
        let r = sender.tag
        guard hasSelection, r < working[currentIndex].endpoints.count else { return }
        working[currentIndex].endpoints[r].favorite.toggle()
        endpointTable.reloadData()
        persist()
    }

    @objc private func addException() {
        guard hasSelection else { return }
        // Clear any blank left from a previous add before making another. Blanks are
        // stripped on the way to disk, so several of them are pure UI litter — and
        // they read as saved entries that simply aren't.
        dropBlankExceptions()
        working[currentIndex].lanAccess.manualExceptionRoutes.append("")
        exceptionTable.reloadData()
        let row = working[currentIndex].lanAccess.manualExceptionRoutes.count - 1
        exceptionTable.scrollRowToVisible(row)
        // Start editing straight away — a blank row is otherwise a dead end.
        exceptionTable.editColumn(0, row: row, with: nil, select: true)
    }

    /// Remove rows that are blank or whitespace-only.
    ///
    /// `persist()` already filters these before writing, so a blank row is never
    /// saved. The problem is what it looks like in the meantime: indistinguishable
    /// from a real entry, and silently dropped when the pane reloads.
    @discardableResult
    private func dropBlankExceptions() -> Bool {
        guard hasSelection else { return false }
        let before = working[currentIndex].lanAccess.manualExceptionRoutes.count
        working[currentIndex].lanAccess.manualExceptionRoutes.removeAll {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return working[currentIndex].lanAccess.manualExceptionRoutes.count != before
    }

    @objc private func removeException() {
        let s = exceptionTable.selectedRow
        guard hasSelection,
              s >= 0, s < working[currentIndex].lanAccess.manualExceptionRoutes.count else { return }
        working[currentIndex].lanAccess.manualExceptionRoutes.remove(at: s)
        exceptionTable.reloadData()
        persist()
    }

    @objc private func addRow() {
        guard hasSelection else { return }
        let keys = Set(working[currentIndex].endpoints.map { $0.key })
        let key = makeKey(from: "endpoint", existing: keys)
        working[currentIndex].endpoints.append(Endpoint(key: key, label: "New Endpoint", host: "vpn.example.com"))
        endpointTable.reloadData()
        endpointTable.scrollRowToVisible(working[currentIndex].endpoints.count - 1)
        persist()
    }

    @objc private func removeRow() {
        let s = endpointTable.selectedRow
        guard hasSelection, s >= 0, s < working[currentIndex].endpoints.count else { return }
        working[currentIndex].endpoints.remove(at: s)
        endpointTable.reloadData()
        persist()
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === profileTable { return working.count }
        guard hasSelection else { return 0 }
        if tableView === exceptionTable { return working[currentIndex].lanAccess.manualExceptionRoutes.count }
        return working[currentIndex].endpoints.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === profileTable {
            guard row < working.count else { return nil }
            // Wrapped in a cell view and pinned to centreY. A bare NSTextField
            // returned here gets its intrinsic height at the top of the row,
            // which reads as the name sitting too high.
            let cell = NSTableCellView()
            let tf = NSTextField(labelWithString: working[row].name)
            tf.lineBreakMode = .byTruncatingTail
            // Renaming happens here rather than in a form field: double-click,
            // or ⋯ ▸ Rename Profile.
            tf.isEditable = true
            tf.isBordered = false
            tf.drawsBackground = false
            tf.delegate = self
            tf.tag = row
            tf.identifier = NSUserInterfaceItemIdentifier("profileName")
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        if tableView === exceptionTable {
            guard hasSelection,
                  row < working[currentIndex].lanAccess.manualExceptionRoutes.count else { return nil }
            let tf = NSTextField()
            tf.isBordered = false; tf.drawsBackground = false
            tf.isEditable = true; tf.tag = row; tf.delegate = self
            tf.identifier = NSUserInterfaceItemIdentifier("exception")
            tf.usesSingleLineMode = true
            tf.lineBreakMode = .byTruncatingTail
            tf.placeholderString = "192.168.1.0/24"
            tf.stringValue = working[currentIndex].lanAccess.manualExceptionRoutes[row]
            return tf
        }
        guard let col = tableColumn, hasSelection,
              row < working[currentIndex].endpoints.count else { return nil }
        let ep = working[currentIndex].endpoints[row]
        let id = col.identifier.rawValue
        if id == "star" {
            let b = NSButton(); b.setButtonType(.momentaryChange); b.isBordered = false
            b.title = ep.favorite ? "★" : "☆"; b.font = .systemFont(ofSize: 14)
            b.tag = row; b.target = self; b.action = #selector(toggleStar(_:))
            return b
        }
        let tf = NSTextField(); tf.isBordered = false; tf.drawsBackground = false
        tf.isEditable = true; tf.tag = row; tf.delegate = self; tf.identifier = col.identifier
        // A plain NSTextField wraps by default, and a hostname like
        // "vpn-gw-1.example.com" breaks at a hyphen — the second line then gets
        // clipped by the 20pt row, rendering as a bare "vpn-". Keep cells on one
        // line and truncate with an ellipsis instead.
        tf.usesSingleLineMode = true
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        defer {
            // Long labels and hostnames legitimately exceed their column, so make
            // the ellipsis non-lossy instead of widening the table for outliers.
            tf.toolTip = tf.stringValue.isEmpty ? nil : tf.stringValue
        }
        switch id {
        case "key":   tf.stringValue = ep.key
        case "label": tf.stringValue = ep.label
        case "host":  tf.stringValue = ep.host
        case "authgroup":
            tf.stringValue = ep.authgroup
            // Blank means inherit, so show what it would inherit as placeholder
            // text. That distinguishes "same as the profile" from "no group at
            // all", which an empty cell alone cannot.
            let inherited = working[currentIndex].authgroup
            tf.placeholderString = inherited.isEmpty ? "none" : inherited
        default: break
        }
        return tf
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTableView, tv === profileTable, !loading else { return }
        let sel = profileTable.selectedRow
        guard sel >= 0, sel < working.count, sel != currentIndex else { return }
        captureFields()
        persist()
        currentIndex = sel
        loadProfileIntoFields()
    }

    // MARK: - Text editing

    /// Begin inline renaming of the selected row. Bound to a double-click and to
    /// ⋯ ▸ Rename Profile, since double-click alone isn't especially findable.
    @objc private func renameSelectedProfile() {
        guard hasSelection else { return }
        profileTable.editColumn(0, row: currentIndex, with: nil, select: true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !loading else { return }
        guard let control = obj.object as? NSControl else { return }

        // Inline rename from the sidebar.
        if let tf = control as? NSTextField, tf.identifier?.rawValue == "profileName" {
            let row = tf.tag
            guard row >= 0, row < working.count else { return }
            let typed = tf.stringValue.trimmingCharacters(in: .whitespaces)
            // A blank name leaves an unlabelled row and nothing to show in the
            // Active-profile popup, so put the old one back rather than store it.
            if typed.isEmpty {
                tf.stringValue = working[row].name
                return
            }
            working[row].name = typed
            persist()
            return
        }
        // Endpoint cell editors carry the column identifier plus a row tag.
        if let tf = control as? NSTextField, tf.identifier?.rawValue == "exception" {
            let r = tf.tag
            guard hasSelection,
                  r < working[currentIndex].lanAccess.manualExceptionRoutes.count else { return }
            let typed = tf.stringValue.trimmingCharacters(in: .whitespaces)
            // Reject here rather than at connect time: the root helper refuses
            // the whole tunnel over one bad entry, and that failure is only
            // visible in the log.
            if !typed.isEmpty, !VPNRunner.isValidExceptionEntry(typed) {
                NSSound.beep()
                tf.stringValue = working[currentIndex].lanAccess.manualExceptionRoutes[r]
                return
            }
            if typed.isEmpty {
                // Leaving a row empty abandons it rather than parking a blank in the
                // list. Deferred because the table is still finishing this edit
                // session, and reloading inside it leaves the editor orphaned.
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.dropBlankExceptions() else { return }
                    self.exceptionTable.reloadData()
                    self.persist()
                }
                return
            }
            working[currentIndex].lanAccess.manualExceptionRoutes[r] = typed
            persist()
            return
        }
        if let tf = control as? NSTextField, let colId = tf.identifier?.rawValue,
           ["key", "label", "host", "authgroup"].contains(colId) {
            let r = tf.tag
            guard hasSelection, r < working[currentIndex].endpoints.count else { return }
            let v = tf.stringValue.trimmingCharacters(in: .whitespaces)
            switch colId {
            case "key":   working[currentIndex].endpoints[r].key = v
            case "label": working[currentIndex].endpoints[r].label = v
            case "host":  working[currentIndex].endpoints[r].host = v
            case "authgroup":
                // Clearing the cell restores inheritance rather than setting an
                // empty group, which is why blank is the "unset" representation.
                working[currentIndex].endpoints[r].authgroup = v
            default: break
            }
            persist()
            return
        }
        // Name / exceptions / auth-group editor.
        applyProfile()
    }

}

// ── Logs pane ────────────────────────────────────────────────────────────────
final class LogsPane: SettingsPane {
    override var naturalWidth: CGFloat { 680 }
    override var minimumWidth: CGFloat { 520 }
    override var isResizablePane: Bool { true }

    private var textView: NSTextView!
    private var timer: Timer?

    override func content() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        textView = NSTextView()
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        let natural = scroll.heightAnchor.constraint(equalToConstant: 420)
        natural.priority = .defaultLow
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            natural,
        ])

        let buttons = NSStackView(views: [button("Refresh", #selector(refreshAction), width: 90),
                                          button("Open in Console", #selector(openConsole), width: 150)])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let body = column([scroll, buttons], spacing: 12)
        scroll.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        return body
    }

    @objc private func refreshAction() { refresh() }

    func refresh() {
        loadViewIfNeeded()
        let log = VPNRunner.shared.readLog()
        textView.string = log.isEmpty ? "(no log yet — connect to generate output)" : log
        textView.scrollToEndOfDocument(nil)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let l = VPNRunner.shared.readLog()
                if l != self.textView.string {
                    self.textView.string = l
                    self.textView.scrollToEndOfDocument(nil)
                }
            }
        }
    }

    func stopTimer() { timer?.invalidate(); timer = nil }

    @objc private func openConsole() {
        NSWorkspace.shared.open([VPNRunner.shared.logFile],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }
}

// Safe indexing helper.
extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
