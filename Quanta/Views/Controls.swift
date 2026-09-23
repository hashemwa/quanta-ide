import AppKit
import SwiftUI

enum DS {
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 12
        static let xl: CGFloat = 16
        static let bar: CGFloat = 10
    }

    enum Radius {
        static let small: CGFloat = 4
        static let control: CGFloat = 5
        static let card: CGFloat = 10
        static let panel: CGFloat = 8
    }

    enum Bar {
        static let primary: CGFloat = 32
        static let secondary: CGFloat = 28
        static let footer: CGFloat = 32
        static let strip: CGFloat = 28
    }

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.15)
        static let hover = Animation.easeOut(duration: 0.12)
        static let activityDelay: TimeInterval = 0.4
    }

    enum Layout {
        static let sidebarMin: CGFloat = 260
        static let sidebarIdeal: CGFloat = 290
        static let sidebarMax: CGFloat = 480
        static let editorColumnIdeal: CGFloat = 720
        static let windowMinWidth: CGFloat = 1200
        static let windowMinHeight: CGFloat = 760
        static let editorPaneMin: CGFloat = 280
        static let paletteWidth: CGFloat = 580
        static let paletteHeight: CGFloat = 390
        static let inspectionWidth: CGFloat = 440
        static let inspectionHeight: CGFloat = 360
        static let findFieldMinWidth: CGFloat = 80
        static let findFieldIdealWidth: CGFloat = 260
        static let tabMinWidth: CGFloat = 96
        static let tabMaxWidth: CGFloat = 220
        static let outputMaxWidth: CGFloat = 760
        static let outputMaxHeight: CGFloat = 620
        static let richOutputHeight: CGFloat = 300
        static let plotListWidth: CGFloat = 190
        static let plotThumbnailHeight: CGFloat = 64
        static let plotsDefaultHeight: CGFloat = 360
        static let plotControlsMinWidth: CGFloat = 96
        static let consoleMinHeight: CGFloat = 100
        static let consoleDefaultHeight: CGFloat = 180
        static let inspectorMin: CGFloat = 220
        static let inspectorIdeal: CGFloat = 280
        static let inspectorMax: CGFloat = 480
        static let statusDot: CGFloat = 6
        static let listRowMinHeight: CGFloat = 24
        static let slot: CGFloat = 22
        static let iconSlot: CGFloat = 16
        static let statusSlot: CGFloat = 14
        static let kernelLabelWidth: CGFloat = 244
        static let kernelLabelMinWidth: CGFloat = 140
        static let symbolGlyph: CGFloat = 10
        static let kernelGlyph: CGFloat = 12
        static let cellGutterWidth: CGFloat = 48
        static let cellTextInset: CGFloat = Space.s + Space.xs + 5
        static let notebookReadingWidth: CGFloat = 1030
        static let notebookSidePadding: CGFloat = 24
        static let notebookTopPadding: CGFloat = 30
        static let notebookCellSpacing: CGFloat = 20
        static let notebookProseSpacing: CGFloat = Space.xs
        static let hairline: CGFloat = 1
        static let selectionBar: CGFloat = 3
        static let commitLines = 1...5
        static let diffMarkerWidth: CGFloat = 16
        static let diffLineInset: CGFloat = 1
        static let diffContextLines = 3
    }

    enum Status {
        case neutral, error, warning
    }

    enum StatusColors {
        static let warning = color(light: 0x805B00, dark: 0xF5D04C)
        static let success = color(light: 0x176B36, dark: 0x73D99A)

        private static func color(light: Int, dark: Int) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
            })
        }
    }

    enum Stream {
        static let stderrRule = Color.orange
    }

    enum Git {
        static let added = Color.green
        static let modified = Color.orange
        static let removed = Color.red
        static let addedFill = Color.green.opacity(0.12)
        static let removedFill = Color.red.opacity(0.12)

        static func color(for status: GitChange.Status) -> Color {
            switch status {
            case .modified, .typeChanged: return modified
            case .added, .untracked, .renamed, .copied: return added
            case .deleted, .conflicted: return removed
            }
        }

        static func nsColor(for status: GitChange.Status) -> NSColor {
            switch status {
            case .modified, .typeChanged: return .systemOrange
            case .added, .untracked, .renamed, .copied: return .systemGreen
            case .deleted, .conflicted: return .systemRed
            }
        }
    }
}

struct FloatingToolbar<Content: View>: View {
    var visible: Bool = true
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 0) {
                    strip.glassEffect(visible ? .regular : .identity, in: .capsule)
                }
            } else {
                strip
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
        }
        .background(ArrowCursorZone(active: visible))
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(reduceMotion ? nil : DS.Motion.hover, value: visible)
    }

    private var strip: some View {
        HStack(spacing: DS.Space.xxs) { content }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(height: DS.Bar.strip)
            .environment(\.iconButtonSize, .strip)
    }
}

struct PlotControlBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: DS.Space.xxs) {
            Spacer(minLength: 0)
            content
        }
        .frame(minHeight: DS.Bar.strip)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plot controls")
    }
}

struct PlotErrorMessage: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(DS.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .accessibilityLabel("Plot error: \(message)")
    }
}

private struct MonoFontSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 12
}

extension EnvironmentValues {
    var monoFontSize: CGFloat {
        get { self[MonoFontSizeKey.self] }
        set { self[MonoFontSizeKey.self] = newValue }
    }
}

private struct IconButtonSizeKey: EnvironmentKey {
    static let defaultValue: IconButton.Size = .embedded
}

extension EnvironmentValues {
    var iconButtonSize: IconButton.Size {
        get { self[IconButtonSizeKey.self] }
        set { self[IconButtonSizeKey.self] = newValue }
    }
}

struct ToolbarDivider: View {
    var body: some View {
        Divider().frame(height: 12)
    }
}

struct IconButton: View {
    enum Size {
        case embedded, strip

        var glyph: CGFloat {
            switch self {
            case .embedded: return 11
            case .strip: return 12
            }
        }

        var extent: CGFloat { DS.Layout.slot }
    }

    let icon: String
    let help: String
    var isActive = false
    var size: Size? = nil
    var symbolWeight: Font.Weight = .regular
    var glass = false
    let action: () -> Void
    @Environment(\.iconButtonSize) private var inheritedSize

    init(_ icon: String, help: String, isActive: Bool = false, size: Size? = nil,
         symbolWeight: Font.Weight = .regular, glass: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.help = help
        self.isActive = isActive
        self.size = size
        self.symbolWeight = symbolWeight
        self.glass = glass
        self.action = action
    }

    var body: some View {
        let metrics = size ?? inheritedSize
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: metrics.glyph, weight: symbolWeight))
                .frame(width: metrics.extent, height: metrics.extent)
        }
        .buttonStyle(IconButtonStyle(isActive: isActive, shape: Self.shape(for: metrics, glass: glass),
                                     glass: glass))
        .help(help)
        .accessibilityLabel(Self.accessibilityName(help))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    static func shape(for size: Size, glass: Bool = false) -> AnyShape {
        if glass { return AnyShape(Circle()) }
        return size == .strip ? AnyShape(Capsule())
                              : AnyShape(RoundedRectangle(cornerRadius: DS.Radius.control))
    }

    static func accessibilityName(_ help: String) -> String {
        guard let paren = help.firstIndex(of: "(") else { return help }
        return help[..<paren].trimmingCharacters(in: .whitespaces)
    }
}

struct IconButtonStyle: ButtonStyle {
    var isActive = false
    var shape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: DS.Radius.control))
    var glass = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .background {
                ZStack {
                    if glass {
                        if #available(macOS 26.0, *) {
                            shape.fill(.clear)
                        } else {
                            shape.fill(.regularMaterial)
                        }
                    } else {
                        shape.fill(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                                            : AnyShapeStyle(.clear))
                    }
                    shape.fill(configuration.isPressed
                               ? AnyShapeStyle(.tertiary)
                               : hovering ? AnyShapeStyle(.quaternary)
                               : AnyShapeStyle(.clear))
                }
            }
            .contentShape(shape)
            .modifier(GlassIconChrome(shape: shape, enabled: glass))
            .scrollAwareHover($hovering)
    }
}

private struct GlassIconChrome: ViewModifier {
    var shape: AnyShape
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
        } else {
            content
        }
    }
}

struct IconMenu<Content: View>: View {
    let icon: String
    let help: String
    var glass = false
    @ViewBuilder var content: Content
    @Environment(\.iconButtonSize) private var inheritedSize

    init(_ icon: String, help: String, glass: Bool = false, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.help = help
        self.glass = glass
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: icon)
                .font(.system(size: inheritedSize.glyph))
                .frame(width: inheritedSize.extent, height: inheritedSize.extent)
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle(shape: IconButton.shape(for: inheritedSize, glass: glass), glass: glass))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(IconButton.accessibilityName(help))
    }
}

struct PanelBar<Content: View>: View {
    enum Rule { case none, below, above }

    var height: CGFloat = DS.Bar.secondary
    var rule: Rule = .none
    var horizontalPadding: CGFloat = DS.Space.bar
    @ViewBuilder var content: Content

    init(height: CGFloat = DS.Bar.secondary, rule: Rule = .none,
         horizontalPadding: CGFloat = DS.Space.bar,
         @ViewBuilder content: () -> Content) {
        self.height = height
        self.rule = rule
        self.horizontalPadding = horizontalPadding
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            if rule == .above { Divider() }
            HStack(spacing: DS.Space.s) { content }
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
            if rule == .below { Divider() }
        }
    }
}

struct NavigatorEmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    let detail: String
    @ViewBuilder var actions: Actions

    init(_ title: String, systemImage: String, detail: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(spacing: DS.Space.m) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            actions
                .controlSize(.small)
                .padding(.top, DS.Space.xs)
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension NavigatorEmptyState where Actions == EmptyView {
    init(_ title: String, systemImage: String, detail: String) {
        self.init(title, systemImage: systemImage, detail: detail) { EmptyView() }
    }
}

struct PanelHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    var height: CGFloat = DS.Bar.secondary
    @ViewBuilder var trailing: Trailing

    init(_ title: String, systemImage: String, height: CGFloat = DS.Bar.secondary,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.height = height
        self.trailing = trailing()
    }

    var body: some View {
        PanelBar(height: height) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: DS.Space.s)
            trailing
        }
    }
}

struct IconSegmentedControl<Value: Hashable>: View {
    struct Segment: Identifiable {
        let value: Value
        let image: NSImage?
        let title: String
        let help: String
        var id: Value { value }

        init(value: Value, icon: String? = nil, title: String, help: String) {
            self.value = value
            self.image = icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
            self.title = title
            self.help = help
        }
    }

    let segments: [Segment]
    @Binding var selection: Value
    var fillsWidth = true

    var body: some View {
        Picker(selection: $selection) {
            ForEach(segments) { segment in
                Group {
                    if let image = segment.image {
                        Image(nsImage: image)
                    } else {
                        Text(segment.title)
                    }
                }
                .help(segment.help)
                .tag(segment.value)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .modifier(PaneTabsStyle(fillsWidth: fillsWidth))
        .buttonBorderShape(.capsule)
        .tint(nil)
    }
}

private struct PaneTabsStyle: ViewModifier {
    let fillsWidth: Bool

    func body(content: Content) -> some View {
        if #available(macOS 27.0, *) {
            sized(content.pickerStyle(.tabs))
        } else {
            sized(content.pickerStyle(.segmented))
        }
    }

    @ViewBuilder
    private func sized(_ picker: some View) -> some View {
        if !fillsWidth {
            picker.fixedSize()
        } else if #available(macOS 26.0, *) {
            picker.buttonSizing(.flexible).frame(maxWidth: .infinity)
        } else {
            picker.frame(maxWidth: .infinity)
        }
    }
}

struct PanelSearchBar: View {
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var onClose: () -> Void
    @State private var focusRequest = 1
    @State private var handledFocusRequest = 0

    var body: some View {
        PanelBar {
            SearchField(text: $text, prompt: prompt, focusRequest: focusRequest,
                        handledFocusRequest: $handledFocusRequest, onSubmit: onSubmit)
                .accessibilityLabel(prompt)
            IconButton("xmark", help: "Close Search") { onClose() }
        }
    }
}

struct ActivitySlot: View {
    let active: Bool
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if visible {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
                    .transition(.opacity)
            }
        }
            .frame(width: DS.Layout.slot, height: DS.Layout.slot)
            .animation(reduceMotion ? nil : DS.Motion.quick, value: visible)
            .task(id: active) {
                guard active else {
                    visible = false
                    return
                }
                try? await Task.sleep(for: .seconds(DS.Motion.activityDelay))
                guard !Task.isCancelled else { return }
                visible = true
            }
    }
}

struct LabelMenu<Content: View, Label: View>: View {
    let help: String
    let accessibilityName: String?
    @ViewBuilder var content: Content
    @ViewBuilder var label: Label

    init(help: String, accessibilityName: String? = nil,
         @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.help = help
        self.accessibilityName = accessibilityName
        self.content = content()
        self.label = label()
    }

    var body: some View {
        Menu {
            content
        } label: {
            label
                .padding(.horizontal, DS.Space.xs)
                .frame(height: DS.Layout.slot)
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help(help)
        .accessibilityLabel(accessibilityName ?? IconButton.accessibilityName(help))
    }
}

struct Pill: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
    }
}

struct HoverHighlight: ViewModifier {
    var radius: CGFloat = DS.Radius.small
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius)
                .fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
            .scrollAwareHover($hovering)
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = DS.Radius.small) -> some View {
        modifier(HoverHighlight(radius: radius))
    }

    func outputCard(_ status: DS.Status = .neutral) -> some View {
        modifier(OutputCard(status: status))
    }

    func inputCard(focused: Bool = false) -> some View {
        modifier(InputCard(focused: focused))
    }

    func selectionOutline(_ selected: Bool) -> some View {
        overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
            .stroke(selected ? Color.accentColor : Color.clear, lineWidth: DS.Layout.hairline))
    }

    func stderrRule(_ active: Bool) -> some View {
        padding(.leading, active ? DS.Space.s : 0)
            .overlay(alignment: .leading) {
                if active {
                    RoundedRectangle(cornerRadius: DS.Layout.hairline)
                        .fill(DS.Stream.stderrRule)
                        .frame(width: DS.Space.xxs)
                }
            }
    }
}

struct InputCard: ViewModifier {
    var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: DS.Radius.card)
                .fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
                .stroke(focused ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: DS.Layout.hairline))
            .animation(reduceMotion ? nil : DS.Motion.quick, value: focused)
    }
}

struct FilterField: View {
    @Binding var text: String
    var prompt = "Filter"

    var body: some View {
        SearchField(text: $text, prompt: prompt, style: .filter,
                    focusRequest: 0, handledFocusRequest: .constant(0), onSubmit: {})
            .frame(maxWidth: .infinity)
            .accessibilityLabel(prompt)
    }
}

struct SearchField: NSViewRepresentable {
    enum Style { case search, filter }

    @Binding var text: String
    let prompt: String
    var style: Style = .search
    var focusRequest: Int
    @Binding var handledFocusRequest: Int
    let onSubmit: () -> Void
    var submitsImmediately: Bool? = nil
    var allowsEmptySubmission = false

    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusableSearchField()
        field.onWindowAvailable = { [weak coordinator = context.coordinator, weak field] in
            guard let field else { return }
            coordinator?.scheduleFocus(field)
        }
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = submitsImmediately ?? (style == .filter)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyStyle(to: field)
        return field
    }

    private func applyStyle(to field: NSSearchField) {
        field.controlSize = .regular
        guard style == .filter else { return }
        let cell = field.cell as? NSSearchFieldCell
        if cell?.searchButtonCell?.image !== Self.filterIcon {
            cell?.searchButtonCell?.image = Self.filterIcon
            cell?.searchButtonCell?.alternateImage = Self.filterIcon
        }
    }

    private static let filterIcon = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle",
                                            accessibilityDescription: "Filter") ?? NSImage()

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        applyStyle(to: field)
        if field.placeholderString != prompt { field.placeholderString = prompt }
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
        context.coordinator.scheduleFocus(field)
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.isDismantled = true
        (field as? FocusableSearchField)?.onWindowAvailable = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        var isDismantled = false
        private var scheduledFocusRequest: Int?

        init(_ parent: SearchField) { self.parent = parent }

        func scheduleFocus(_ field: NSSearchField) {
            let request = parent.focusRequest
            guard !isDismantled, parent.handledFocusRequest != request,
                  scheduledFocusRequest != request, field.window != nil else { return }
            scheduledFocusRequest = request
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self else { return }
                self.scheduledFocusRequest = nil
                guard !self.isDismantled, self.parent.focusRequest == request,
                      self.parent.handledFocusRequest != request,
                      let field, let window = field.window,
                      !field.isHiddenOrHasHiddenAncestor,
                      window.makeFirstResponder(field) else { return }
                self.parent.handledFocusRequest = request
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.text = field.stringValue
        }

        @objc func submit(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            guard parent.allowsEmptySubmission || !sender.stringValue.isEmpty else { return }
            parent.onSubmit()
        }
    }
}

final class FocusableSearchField: NSSearchField {
    var onWindowAvailable: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindowAvailable?() }
    }
}

struct OutputCard: ViewModifier {
    var status: DS.Status

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(stroke, lineWidth: 1))
    }

    private var fill: AnyShapeStyle {
        switch status {
        case .neutral: return AnyShapeStyle(Color(nsColor: .textBackgroundColor))
        case .error: return AnyShapeStyle(Color.red.opacity(0.10))
        case .warning: return AnyShapeStyle(Color.yellow.opacity(0.10))
        }
    }

    private var stroke: AnyShapeStyle {
        switch status {
        case .neutral: return AnyShapeStyle(Color(nsColor: .separatorColor))
        case .error: return AnyShapeStyle(Color.red.opacity(0.30))
        case .warning: return AnyShapeStyle(Color.yellow.opacity(0.30))
        }
    }
}

struct ArrowCursorZone: NSViewRepresentable {
    var active: Bool

    func makeNSView(context: Context) -> CursorZoneView { CursorZoneView() }

    func updateNSView(_ view: CursorZoneView, context: Context) {
        view.isActive = active
    }
}

final class CursorZoneView: NSView {
    private static let all = NSHashTable<CursorZoneView>.weakObjects()
    private var inside = false

    var isActive = true {
        didSet {
            if !isActive, inside {
                inside = false
                restoreUnderlyingCursor()
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        Self.all.add(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                      .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isActive else { return }
        inside = true
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        if isActive { NSCursor.arrow.set() }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isActive { NSCursor.arrow.set() } else { super.cursorUpdate(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        inside = false
        restoreUnderlyingCursor()
    }

    private func restoreUnderlyingCursor() {
        if let window, let content = window.contentView, let root = content.superview {
            let point = root.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            var view = content.hitTest(point)
            while let current = view {
                if current is NSTextView { NSCursor.iBeam.set(); return }
                view = current.superview
            }
        }
        NSCursor.arrow.set()
    }

    static func contains(windowPoint: NSPoint, in window: NSWindow?) -> Bool {
        guard let window else { return false }
        for zone in all.allObjects
        where zone.isActive && zone.window === window && !zone.isHiddenOrHasHiddenAncestor {
            if zone.convert(zone.bounds, to: nil).contains(windowPoint) { return true }
        }
        return false
    }
}

@MainActor
enum FloatingPanelSurface {
    static func make(content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = DS.Radius.panel
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = DS.Radius.panel
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        return effect
    }
}
