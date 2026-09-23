import AppKit
import SwiftUI

struct NavigatorOutline: NSViewRepresentable {
    let root: FileNode
    let children: [FileNode]
    @Binding var selection: Set<URL>
    let filtering: Bool
    var statusByPath: [String: GitChange.Status] = [:]
    var directoriesWithChanges: Set<String> = []

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let outline = NavigatorOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("files"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.rowHeight = DS.Layout.listRowMinHeight
        outline.menu = NSMenu()
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = DS.Space.l
        outline.allowsMultipleSelection = true
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.backgroundColor = .clear
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.every, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setAccessibilityLabel("Files")
        scroll.documentView = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let outline = scroll.documentView as? NSOutlineView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.updating = true
        defer { coordinator.updating = false }
        var tree = root
        tree.children = children
        let treeChanged = coordinator.tree != tree || coordinator.filtering != filtering
        let statusChanged = coordinator.statusByPath != statusByPath
            || coordinator.directoriesWithChanges != directoriesWithChanges
        coordinator.statusByPath = statusByPath
        coordinator.directoriesWithChanges = directoriesWithChanges
        if treeChanged {
            if !coordinator.filtering {
                coordinator.expanded = Set(coordinator.items.values.filter { outline.isItemExpanded($0) }.map { $0.node.url })
            }
            let firstLoad = coordinator.tree == nil || coordinator.tree?.url != root.url
            coordinator.tree = tree
            coordinator.filtering = filtering
            coordinator.items = [:]
            coordinator.root = coordinator.makeItem(tree, parent: nil)
            outline.reloadData()
            if firstLoad {
                let saved = QuantaDefaults.store.stringArray(forKey: coordinator.expansionKey)
                coordinator.expanded = saved.map { Set($0.map { URL(fileURLWithPath: $0, isDirectory: true) }) } ?? [root.url]
            }
            for item in coordinator.items.values where item.node.isDirectory {
                if filtering || coordinator.expanded.contains(item.node.url) { outline.expandItem(item) }
            }
        } else if statusChanged {
            coordinator.refreshVisibleCells(outline)
        }
        let indexes = IndexSet(selection.compactMap { url in
            guard let item = coordinator.items[url] ?? coordinator.items.values.first(where: {
                $0.node.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
            }) else { return nil }
            let row = outline.row(forItem: item)
            return row >= 0 ? row : nil
        })
        if outline.selectedRowIndexes != indexes {
            outline.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    final class Item: NSObject {
        let node: FileNode
        weak var parent: Item?
        var children: [Item] = []
        init(_ node: FileNode, parent: Item?) {
            self.node = node
            self.parent = parent
        }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: NavigatorOutline
        var tree: FileNode?
        var root: Item?
        var items: [URL: Item] = [:]
        var expanded: Set<URL> = []
        var filtering = false
        var updating = false
        var statusByPath: [String: GitChange.Status] = [:]
        var directoriesWithChanges: Set<String> = []
        var expansionKey: String { "QuantaNavigatorExpanded.v1.\(parent.root.url.path)" }
        private var app: AppState { AppState.shared }

        init(_ parent: NavigatorOutline) { self.parent = parent }

        func makeItem(_ node: FileNode, parent: Item?) -> Item {
            let item = Item(node, parent: parent)
            items[node.url] = item
            item.children = (node.children ?? []).map { makeItem($0, parent: item) }
            return item
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Item)?.children.count ?? (root == nil ? 0 : 1)
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let item = item as? Item { return item.children[index] }
            return root!
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Item)?.node.isDirectory == true
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? Item else { return nil }
            let cell = outlineView.makeView(withIdentifier: NavigatorCellView.identifier, owner: nil) as? NavigatorCellView
                ?? NavigatorCellView()
            configure(cell, for: item)
            return cell
        }

        private func configure(_ cell: NavigatorCellView, for item: Item) {
            let node = item.node
            cell.configure(node,
                           status: statusByPath[node.url.path],
                           containsChanges: node.isDirectory && directoriesWithChanges.contains(node.url.path))
        }

        func refreshVisibleCells(_ outline: NSOutlineView) {
            for row in 0..<outline.numberOfRows {
                guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NavigatorCellView,
                      let item = outline.item(atRow: row) as? Item else { continue }
                configure(cell, for: item)
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let outline = notification.object as? NSOutlineView else { return }
            let selected = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Item)?.node.url })
            if parent.selection != selected { parent.selection = selected }
        }

        func outlineViewItemDidExpand(_ notification: Notification) { saveExpansion(notification) }
        func outlineViewItemDidCollapse(_ notification: Notification) { saveExpansion(notification) }

        private func saveExpansion(_ notification: Notification) {
            guard !updating, !filtering, let outline = notification.object as? NSOutlineView else { return }
            expanded = Set(items.values.filter { outline.isItemExpanded($0) }.map { $0.node.url })
            QuantaDefaults.store.set(expanded.map(\.path), forKey: expansionKey)
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let item = item as? Item, item !== root else { return nil }
            return item.node.url as NSURL
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let urls = droppedURLs(info), let target = dropTarget(item) else { return [] }
            let destination = target.node.url.path
            for url in urls {
                if destination == url.path || destination.hasPrefix(url.path + "/") { return [] }
            }
            let copying = isCopy(info, outlineView)
            if !copying, urls.allSatisfy({ $0.deletingLastPathComponent().path == destination }) { return [] }
            outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return copying ? .copy : .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            guard let urls = droppedURLs(info), let target = dropTarget(item) else { return false }
            let copying = isCopy(info, outlineView)
            let destination = target.node.url
            DispatchQueue.main.async { [app] in
                app.transferNodes(at: urls, to: destination, copying: copying)
            }
            return true
        }

        private func droppedURLs(_ info: NSDraggingInfo) -> [URL]? {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
                .urlReadingFileURLsOnly: true,
            ]) as? [URL]
            return urls?.isEmpty == false ? urls : nil
        }

        private func dropTarget(_ item: Any?) -> Item? {
            guard let item = item as? Item else { return root }
            return item.node.isDirectory ? item : item.parent
        }

        private func isCopy(_ info: NSDraggingInfo, _ outlineView: NSOutlineView) -> Bool {
            let internalDrag = (info.draggingSource as? NSOutlineView) === outlineView
            return !internalDrag || info.draggingSourceOperationMask == .copy
        }

        func menu(forClickedRow row: Int, in outline: NSOutlineView) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let clicked = row >= 0 ? outline.item(atRow: row) as? Item : nil
            let selectedItems = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Item }
            let targets: [Item]
            if let clicked, !selectedItems.contains(where: { $0 === clicked }) {
                targets = [clicked]
            } else if clicked != nil {
                targets = selectedItems
            } else {
                targets = []
            }
            let rootURL = parent.root.url
            let urls = targets.filter { $0 !== root }.map(\.node.url)
            if targets.count == 1, let item = targets.first {
                let node = item.node
                if node.isDirectory {
                    menu.addItem(ActionMenuItem("New File…") { [app] in app.createFile(in: node.url) })
                    menu.addItem(ActionMenuItem("New Folder…") { [app] in app.createFolder(in: node.url) })
                    menu.addItem(ActionMenuItem("Paste") { [app] in app.pasteNodes(into: node.url) })
                } else {
                    menu.addItem(ActionMenuItem("Open") { [app] in app.openFile(node.url) })
                    if statusByPath[node.url.path] != nil {
                        menu.addItem(ActionMenuItem("Show Changes") { [app] in app.openDiff(forFileAt: node.url) })
                    }
                }
                menu.addItem(.separator())
                if item !== root {
                    menu.addItem(ActionMenuItem("Rename…") { [app] in app.renameNode(node) })
                }
            } else if targets.isEmpty {
                menu.addItem(ActionMenuItem("New File…") { [app] in app.createFile(in: rootURL) })
                menu.addItem(ActionMenuItem("New Folder…") { [app] in app.createFolder(in: rootURL) })
                menu.addItem(ActionMenuItem("Paste") { [app] in app.pasteNodes(into: rootURL) })
                menu.addItem(.separator())
            }
            if !urls.isEmpty {
                menu.addItem(ActionMenuItem("Move To…") { [app] in app.chooseDestinationAndMoveNodes(at: urls) })
                menu.addItem(ActionMenuItem("Duplicate") { [app] in app.duplicateNodes(at: urls) })
                menu.addItem(ActionMenuItem("Copy") { [app] in app.copyNodes(at: urls) })
                menu.addItem(ActionMenuItem("Move to Trash") { [app] in app.trashNodes(at: urls) })
                menu.addItem(.separator())
            }
            let revealed = urls.isEmpty ? [rootURL] : urls
            menu.addItem(ActionMenuItem("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(revealed)
            })
            if revealed.count == 1, let url = revealed.first {
                menu.addItem(ActionMenuItem("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                })
            }
            return menu
        }

        func trashSelection(in outline: NSOutlineView) {
            let urls = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Item }
                .filter { $0 !== root }
                .map(\.node.url)
            guard !urls.isEmpty else { return }
            app.trashNodes(at: urls)
        }
    }
}

final class NavigatorOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        _ = super.menu(for: event)
        let row = clickedRow >= 0 ? clickedRow : self.row(at: convert(event.locationInWindow, from: nil))
        return (delegate as? NavigatorOutline.Coordinator)?.menu(forClickedRow: row, in: self)
    }

    override func keyDown(with event: NSEvent) {
        let isDelete = event.keyCode == 51 || event.keyCode == 117
        if isDelete, event.modifierFlags.contains(.command) {
            (delegate as? NavigatorOutline.Coordinator)?.trashSelection(in: self)
            return
        }
        super.keyDown(with: event)
    }
}

final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

final class NavigatorCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("NavigatorCell")

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let changeDot = NSImageView()
    private var nodeName = ""
    private var deleted = false
    private var iconColor: NSColor = .secondaryLabelColor
    private var statusColor: NSColor = .secondaryLabelColor

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = icon
        textField = name
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .body)
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        status.alignment = .right
        changeDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Contains changes")
        changeDot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: DS.Layout.statusDot, weight: .regular)
        for view in [icon, name, status, changeDot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: DS.Layout.iconSlot),
            icon.heightAnchor.constraint(equalToConstant: DS.Layout.iconSlot),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: DS.Space.s),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -DS.Space.s),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.xs),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: DS.Layout.statusSlot),
            changeDot.centerXAnchor.constraint(equalTo: status.centerXAnchor),
            changeDot.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    func configure(_ node: FileNode, status change: GitChange.Status?, containsChanges: Bool) {
        nodeName = node.name
        deleted = change == .deleted
        icon.image = NSImage(systemSymbolName: node.isDirectory ? "folder.fill" : node.iconName,
                             accessibilityDescription: nil)
        iconColor = node.isDirectory ? .controlAccentColor : .secondaryLabelColor
        if let change {
            status.stringValue = change.letter
            status.toolTip = change.label
            status.setAccessibilityLabel(change.label)
            statusColor = DS.Git.nsColor(for: change)
            status.isHidden = false
            changeDot.isHidden = true
        } else {
            status.stringValue = ""
            status.isHidden = true
            changeDot.isHidden = !containsChanges
        }
        toolTip = node.url.path
        applyColors()
    }

    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        let textColor: NSColor = emphasized ? .alternateSelectedControlTextColor
                                            : (deleted ? .secondaryLabelColor : .labelColor)
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: textColor,
            .font: name.font ?? .systemFont(ofSize: NSFont.systemFontSize),
        ]
        if deleted { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        name.attributedStringValue = NSAttributedString(string: nodeName, attributes: attributes)
        icon.contentTintColor = emphasized ? .alternateSelectedControlTextColor : iconColor
        status.textColor = emphasized ? .alternateSelectedControlTextColor : statusColor
        changeDot.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}
