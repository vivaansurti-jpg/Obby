import SwiftUI
import AppKit

struct SidebarDrag: Codable, Equatable {
    let id: UUID
    let root: String
    let path: String
}

extension AppModel {
    /// Records the item being dragged in the sidebar; drops are only accepted for this exact drag.
    @discardableResult func beginSidebarDrag(_ path: String) -> SidebarDrag? {
        guard let vault else { return nil }
        let drag = SidebarDrag(id: UUID(), root: vault.root.path, path: path)
        sidebarDrag = drag
        return drag
    }
    func dropDestination(for drag: SidebarDrag, folder: String) throws -> String {
        guard drag == sidebarDrag, let vault, vault.root.path == drag.root else { throw ObbyError("Start the drag again in the current Obby folder.") }
        let destinationFolder = try vault.resolve(folder, allowRoot: true)
        guard try destinationFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ObbyError("Drop onto a folder.") }
        let name = try vault.resolve(drag.path).lastPathComponent
        let destination = folder.isEmpty ? name : folder + "/" + name
        // Conflicts are allowed as drop targets so the drop can explain the conflict.
        try vault.validateMove(drag.path, destination, checkConflict: false)
        return destination
    }
    @discardableResult func moveSidebarItem(_ drag: SidebarDrag, to folder: String) -> Bool {
        guard save() else { return false }
        defer { sidebarDrag = nil }
        do {
            let destination = try dropDestination(for: drag, folder: folder)
            guard let vault else { return false }
            try vault.move(drag.path, destination)
            directoryResults.removeAll()
            didMove(drag.path, destination)
            refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

// NSOutlineView owns the entire drag session, including row hit-testing and
// native drop highlighting. SwiftUI List row drop handlers are not used here.
struct NativeFileSidebar: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Files"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil; outline.rowHeight = 26
        outline.style = .sourceList
        outline.allowsMultipleSelection = false
        outline.autoresizesOutlineColumn = true
        outline.dataSource = context.coordinator; outline.delegate = context.coordinator
        outline.registerForDraggedTypes([Coordinator.pasteboardType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        let menu = NSMenu()
        for (title, action) in [("Rename…", #selector(Coordinator.rename)), ("Move…", #selector(Coordinator.move)), ("Folder Context…", #selector(Coordinator.folderContext)), ("Move to Trash…", #selector(Coordinator.remove))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = context.coordinator; menu.addItem(item)
        }
        outline.menu = menu
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        scroll.documentView = outline
        context.coordinator.outline = outline
        context.coordinator.update()
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update() }
    final class Node: NSObject {
        var entry: Entry
        var children: [Node] = []
        init(_ entry: Entry) { self.entry = entry }
    }
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        static let pasteboardType = NSPasteboard.PasteboardType("local.obby.sidebar-item")
        let model: AppModel
        weak var outline: NSOutlineView?
        var roots: [Node] = []
        var nodes: [String: Node] = [:]
        var previous: [Entry] = []
        var updating = false
        init(_ model: AppModel) { self.model = model }
        func update() {
            guard let outline else { return }
            let entries = [Entry(path: "", isDirectory: true)] + (model.query.isEmpty ? model.tree : model.results)
            updating = true
            defer { updating = false }
            if entries != previous {
                let expanded = nodes.filter { outline.isItemExpanded($0.value) }.map(\.key)
                let old = nodes
                nodes = [:]
                func build(_ entry: Entry) -> Node {
                    let node = old[entry.path] ?? Node(entry)
                    node.entry = entry
                    node.children = (entry.children ?? []).map(build)
                    nodes[entry.path] = node
                    return node
                }
                roots = entries.map(build)
                previous = entries
                outline.reloadData()
                for path in expanded.sorted(by: { $0.count < $1.count }) {
                    if let node = nodes[path] { outline.expandItem(node) }
                }
            }
            if let node = nodes[model.selection ?? ""] {
                let selected = model.selection ?? ""
                let ancestors = selected.split(separator: "/").dropLast()
                var path = ""
                for component in ancestors {
                    path = path.isEmpty ? String(component) : path + "/" + component
                    if let parent = nodes[path] { outline.expandItem(parent) }
                }
                let row = outline.row(forItem: node)
                if row >= 0 && outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            } else { outline.deselectAll(nil) }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? Node)?.children ?? roots)[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { guard let node = item as? Node else { return false }; return node.entry.isDirectory && !node.entry.path.isEmpty }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            let label = NSTextField(labelWithString: node.entry.path.isEmpty ? "All Notes" : node.entry.name)
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
            label.lineBreakMode = .byTruncatingTail
            let icon = NSImageView(image: NSImage(systemSymbolName: node.entry.isDirectory ? "folder" : "doc.text", accessibilityDescription: nil)!)
            icon.contentTintColor = node.entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
            let cell = NSTableCellView()
            cell.imageView = icon; cell.textField = label
            for view in [icon, label] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let outline else { return }
            let node = outline.item(atRow: outline.selectedRow) as? Node
            guard let node else { model.selection = nil; return }
            if node.entry.isDirectory { model.selectFolder(node.entry.path.isEmpty ? nil : node.entry.path) } // Closes the open note.
            else { model.selection = node.entry.path; model.openNote(node.entry.path) }
        }
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? Node, !node.entry.path.isEmpty, let drag = model.beginSidebarDrag(node.entry.path), let data = try? JSONEncoder().encode(drag) else { return nil }
            let pasteboard = NSPasteboardItem()
            pasteboard.setData(data, forType: Self.pasteboardType)
            return pasteboard
        }
        func drop(_ info: NSDraggingInfo, item: Any?) -> (SidebarDrag, String)? {
            guard info.draggingSource as? NSOutlineView === outline,
                  let data = info.draggingPasteboard.data(forType: Self.pasteboardType),
                  let drag = try? JSONDecoder().decode(SidebarDrag.self, from: data) else { return nil }
            let node = item as? Node
            guard node == nil || node?.entry.isDirectory == true else { return nil }
            let folder = node?.entry.path ?? ""
            guard (try? model.dropDestination(for: drag, folder: folder)) != nil else { return nil }
            return (drag, folder)
        }
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard drop(info, item: item) != nil else { return [] }
            outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard let (drag, folder) = drop(info, item: item) else { return false }
            let moved = model.moveSidebarItem(drag, to: folder)
            update()
            return moved
        }
        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { model.sidebarDrag = nil }
        var contextPath: String? { guard let outline, let path = (outline.item(atRow: outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow) as? Node)?.entry.path, !path.isEmpty else { return nil }; return path }
        @objc func rename() { if let path = contextPath { model.relocate(path, rename: true) } }
        @objc func move() { if let path = contextPath { model.relocate(path, rename: false) } }
        @objc func remove() { if let path = contextPath { model.remove(path) } }
        @objc func folderContext() { if let path = contextPath { model.editFolderContext(path) } }
    }
}
