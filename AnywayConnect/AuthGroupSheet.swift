import AppKit

// ── Auth group chooser ───────────────────────────────────────────────────────
//
// Asks one gateway which auth groups it advertises, and lets the user pick one.
//
// It exists as a sheet rather than a dropdown on the form for two reasons. The
// list is server-side state — tunnel groups configured on that appliance — so it
// is deliberately never cached; a stale list that looks authoritative is worse
// than no list. And reading it is not a cheap lookup: it runs openconnect against
// the gateway with a deliberately invalid --authgroup, which is a full TLS
// handshake taking seconds and which can land in a posture check or SSO. That is
// far too heavy to hang off opening a menu, and it needs somewhere to show
// progress and explain a failure.
//
// The endpoint is chosen explicitly because the answer belongs to a specific host.
// The form's previous behaviour — silently probing endpoints.first and applying the
// result profile-wide — hid that entirely.

final class AuthGroupSheet: NSViewController {

    /// One content width for every row in the sheet.
    private static let contentWidth: CGFloat = 470
    private static let rowHeight: CGFloat = 20
    private static let visibleRows = 7

    enum Scope { case endpointOnly, profileDefault }
    struct Choice { let group: String; let endpointKey: String; let scope: Scope }

    private let endpoints: [Endpoint]
    private let protocolName: String
    private let csdWrapper: String
    private let currentValue: String
    private let onUse: (Choice) -> Void

    private var endpointPopup: NSPopUpButton!
    private var refetchButton: NSButton!
    private var table: NSTableView!
    private var spinner: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var scopeEndpoint: NSButton!
    private var scopeProfile: NSButton!
    private var useButton: NSButton!

    private var groups: [String] = []
    /// Bumped on every fetch so a slow reply for a gateway the user has already
    /// navigated away from is discarded instead of overwriting the current list.
    private var fetchGeneration = 0

    /// Seam over the probe. Injectable so the sheet's states — in flight, results,
    /// nothing advertised, posture required — can be exercised without a real TLS
    /// handshake to a production gateway.
    typealias Fetcher = (_ host: String, _ protocolName: String, _ csdWrapper: String,
                         _ completion: @escaping ([String], String) -> Void) -> Void

    var fetcher: Fetcher = { host, protocolName, csdWrapper, completion in
        VPNRunner.shared.fetchAuthGroups(host: host, protocolName: protocolName,
                                        csdWrapper: csdWrapper, completion: completion)
    }

    init(endpoints: [Endpoint], protocolName: String, csdWrapper: String,
         currentValue: String, onUse: @escaping (Choice) -> Void) {
        self.endpoints = endpoints
        self.protocolName = protocolName
        self.csdWrapper = csdWrapper
        self.currentValue = currentValue
        self.onUse = onUse
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    override func loadView() {
        let title = NSTextField(labelWithString: "Choose auth group")
        title.font = .boldSystemFont(ofSize: 13)

        let blurb = wrapping("The gateway is asked each time — the list isn't saved, "
                           + "because it can change on the server.")

        endpointPopup = NSPopUpButton()
        endpointPopup.target = self
        endpointPopup.action = #selector(endpointChanged)
        for ep in endpoints {
            let label = ep.label.isEmpty ? ep.key : ep.label
            endpointPopup.addItem(withTitle: "\(label) — \(ep.host)")
        }
        // Favourite first if there is one: it's the endpoint the user actually uses.
        if let fav = endpoints.firstIndex(where: { $0.favorite }) {
            endpointPopup.selectItem(at: fav)
        }
        endpointPopup.translatesAutoresizingMaskIntoConstraints = false
        // Absorbs the slack in its row rather than fixing a width: the label and
        // button widths depend on the system font, so hardcoding the popup made the
        // row overrun the sheet and the stack then centred it, pushing the row's
        // left edge outside the content margin.
        endpointPopup.setContentHuggingPriority(.init(1), for: .horizontal)
        endpointPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        refetchButton = NSButton(title: "Ask again", target: self, action: #selector(startFetch))
        refetchButton.bezelStyle = .rounded
        refetchButton.controlSize = .small
        refetchButton.font = .systemFont(ofSize: 11)

        table = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("group"))
        col.title = "Advertised groups"
        col.width = 380
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Self.rowHeight
        // No vertical gap, so the visible height below is an exact row count.
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.doubleAction = #selector(use)
        table.target = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // Sized to a whole number of rows plus the bezel. An arbitrary height left
        // a half-drawn row sliced across the bottom edge, which reads as broken
        // rather than as "scroll for more". Eight groups is a real answer from these
        // gateways, so seven visible is a reasonable window.
        scroll.heightAnchor.constraint(
            equalToConstant: Self.rowHeight * CGFloat(Self.visibleRows) + 4).isActive = true

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true

        statusLabel = wrapping("")
        // Two lines reserved: the CSD and SSO explanations are long, and a status
        // line that changes height would resize the sheet mid-fetch.
        statusLabel.maximumNumberOfLines = 2
        let lh = ceil(statusLabel.font!.boundingRectForFont.height)
        statusLabel.heightAnchor.constraint(equalToConstant: lh * 2).isActive = true
        // Deliberately NOT paired with the spinner in a row. Sharing a row left the
        // text indented behind space the stopped spinner still occupied, so it
        // failed to line up with every other row in the sheet.

        scopeEndpoint = NSButton(radioButtonWithTitle: "Only this endpoint",
                                 target: self, action: #selector(scopeChanged))
        scopeProfile = NSButton(radioButtonWithTitle: "Every endpoint in this profile",
                                target: self, action: #selector(scopeChanged))
        scopeProfile.state = .on

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        useButton = NSButton(title: "Use Group", target: self, action: #selector(use))
        useButton.bezelStyle = .rounded
        useButton.keyEquivalent = "\r"
        useButton.isEnabled = false

        // The spinner lives beside the control that triggers the work, not in front
        // of the status text. Its space is reserved whether or not it is animating,
        // so nothing moves when a fetch starts or ends.
        let gatewayRow = NSStackView(views: [NSTextField(labelWithString: "Gateway:"),
                                             endpointPopup, spinner, refetchButton])
        gatewayRow.orientation = .horizontal
        gatewayRow.alignment = .centerY
        gatewayRow.distribution = .fill
        gatewayRow.spacing = 8

        let scopeBox = NSStackView(views: [NSTextField(labelWithString: "Apply to:"),
                                           scopeProfile, scopeEndpoint])
        scopeBox.orientation = .horizontal
        scopeBox.spacing = 10

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, cancel, useButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let stack = NSStackView(views: [title, blurb, gatewayRow, scroll,
                                        statusLabel, scopeBox, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Every row is exactly as wide as the stack. Leading alignment only lines
        // rows up when they agree on width: a row wider than the others was centred
        // instead, and the Gateway row — the widest — ended up starting outside the
        // left margin entirely.
        //
        // The margin comes from constraints rather than edgeInsets. With insets, the
        // rows and the stack were both pinned to the same width and the insets were
        // squeezed to nothing, leaving the content flush against the sheet edge.
        for v in [title, blurb, gatewayRow, scroll, statusLabel, scopeBox, buttonRow] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let root = NSView()
        root.addSubview(stack)
        let m: CGFloat = 20
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: m),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -m),
        ])
        view = root
    }

    private func wrapping(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.isSelectable = false
        l.preferredMaxLayoutWidth = Self.contentWidth
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Opening the sheet is the explicit action, so fetch straight away rather
        // than making the user press a button they have no reason not to press.
        startFetch()
    }

    // MARK: - Fetching

    private var selectedEndpoint: Endpoint? {
        let i = endpointPopup.indexOfSelectedItem
        guard i >= 0, i < endpoints.count else { return nil }
        return endpoints[i]
    }

    @objc private func endpointChanged() { startFetch() }

    @objc private func startFetch() {
        guard let ep = selectedEndpoint else { return }
        fetchGeneration += 1
        let generation = fetchGeneration

        groups = []
        table.reloadData()
        useButton.isEnabled = false
        refetchButton.isEnabled = false
        spinner.startAnimation(nil)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Asking \(ep.host)… this can take a few seconds."

        fetcher(ep.host, protocolName, csdWrapper) { [weak self] groups, hint in
            guard let self = self, generation == self.fetchGeneration else { return }
            self.spinner.stopAnimation(nil)
            self.refetchButton.isEnabled = true
            self.groups = groups
            self.table.reloadData()

            if groups.isEmpty {
                // The hints distinguish "posture check first", "SSO, no groups" and
                // "none advertised" — worth showing in place instead of a modal
                // alert stacked on top of the sheet.
                self.statusLabel.textColor = .secondaryLabelColor
                self.statusLabel.stringValue = hint.isEmpty
                    ? "\(ep.host) didn't advertise a group list. Leaving the auth group blank usually works."
                    : hint
                self.useButton.isEnabled = false
                return
            }

            self.statusLabel.textColor = .secondaryLabelColor
            self.statusLabel.stringValue = "\(ep.host) advertises "
                + "\(groups.count) group\(groups.count == 1 ? "" : "s")."
            // Preselect whatever is already configured, so reopening the sheet
            // shows the current choice rather than jumping to the top of the list.
            let preselect = groups.firstIndex(of: self.currentValue) ?? 0
            self.table.selectRowIndexes([preselect], byExtendingSelection: false)
            self.useButton.isEnabled = true
        }
    }

    // MARK: - Actions

    @objc private func scopeChanged() {}

    @objc private func cancel() {
        presentingViewController?.dismiss(self)
    }

    @objc private func use() {
        let row = table.selectedRow
        guard row >= 0, row < groups.count, let ep = selectedEndpoint else { return }
        let scope: Scope = (scopeEndpoint.state == .on) ? .endpointOnly : .profileDefault
        onUse(Choice(group: groups[row], endpointKey: ep.key, scope: scope))
        presentingViewController?.dismiss(self)
    }
}

extension AuthGroupSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { groups.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("groupCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? {
                let c = NSTableCellView()
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                c.identifier = id
                return c
            }()
        cell.textField?.stringValue = groups[row]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        useButton.isEnabled = table.selectedRow >= 0 && !groups.isEmpty
    }
}
