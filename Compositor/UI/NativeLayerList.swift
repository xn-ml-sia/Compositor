import AppKit
import SwiftUI

/// Native mouse-down selection and drag tracking, without a double-click delay.
struct NativeLayerList: NSViewRepresentable {
    let session: EditorSession
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = LayerTableView()
        table.session = session
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 52
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
        column.width = 252
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.renameClickedLayer(_:))
        table.action = #selector(Coordinator.clickedLayer(_:))
        table.registerForDraggedTypes([Coordinator.layerType, Coordinator.maskType, Coordinator.effectType])
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.setAccessibilityIdentifier("layersList")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        context.coordinator.update(table)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let table = scroll.documentView as? NSTableView { context.coordinator.update(table) }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
        static let layerType = NSPasteboard.PasteboardType("com.compositor.layer-row")
        /// An Option-drag from a mask thumbnail: the id of the layer whose mask is being copied.
        static let effectType = NSPasteboard.PasteboardType("com.compositor.layer-effect")
        static let maskType = NSPasteboard.PasteboardType("com.compositor.layer-mask")
        let session: EditorSession
        private var rows: [ImageLayer] = []
        private var rowDetails: [UUID: LayerHierarchy.Entry] = [:]
        private var oldCollapsed: Set<UUID> = []
        private var editingEnabled = false
        private var synchronizing = false
        init(session: EditorSession) { self.session = session }

        func update(_ table: NSTableView) {
            let entries = session.layerRows
            let byID = Dictionary(uniqueKeysWithValues: (session.document?.layers ?? []).map { ($0.id, $0) })
            let next = entries.compactMap { byID[$0.layer.id] }
            let previousDetails = rowDetails
            rowDetails = Dictionary(uniqueKeysWithValues: entries.map { ($0.layer.id, $0) })
            let expansionChanged = oldCollapsed != session.collapsedGroupIDs
            oldCollapsed = session.collapsedGroupIDs
            let enabled = session.canEditLayers
            synchronizing = true
            defer { synchronizing = false }
            let old = rows
            rows = next
            let editableChanged = editingEnabled != enabled
            editingEnabled = enabled
            if old.map(\.id) != next.map(\.id) {
                table.reloadData()
            } else {
                // Selection never reloads cells or recreates thumbnails.
                let changed = IndexSet(next.indices.filter {
                    editableChanged || expansionChanged || (old[$0].name != next[$0].name || old[$0].isVisible != next[$0].isVisible || old[$0].size != next[$0].size || old[$0].parentID != next[$0].parentID || old[$0].isGroup != next[$0].isGroup || old[$0].asset?.image !== next[$0].asset?.image || (old[$0].liveText != nil) != (next[$0].liveText != nil) || old[$0].effects != next[$0].effects || old[$0].mask != next[$0].mask || old[$0].maskSourceID != next[$0].maskSourceID) || previousDetails[next[$0].id]?.depth != rowDetails[next[$0].id]?.depth || previousDetails[next[$0].id]?.visible != rowDetails[next[$0].id]?.visible
                })
                let resized = IndexSet(next.indices.filter { (old[$0].effects?.kinds.count ?? 0) != (next[$0].effects?.kinds.count ?? 0) })
                // Adding or removing an effect only changes how tall a row is. Left to AppKit that is animated, and
                // the row appears to be taken away and put back; here it simply becomes its new height.
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                if !resized.isEmpty { table.noteHeightOfRows(withIndexesChanged: resized) }
                if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
                NSAnimationContext.endGrouping()
            }
            let indices = IndexSet(next.indices.filter { session.selectedEffect == nil && session.selectedLayerIDs.contains(next[$0].id) })
            if table.selectedRowIndexes != indices { table.selectRowIndexes(indices, byExtendingSelection: false) }
            // Border-only updates: selecting a target never rebuilds thumbnails or canvas pixels.
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound {
                for row in visible.location..<min(next.count, NSMaxRange(visible)) {
                    (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? LayerCell)?.updateTarget()
                }
            }
            // A rename — double-click, the row's menu, or the Layer menu — is typed in the row itself.
            if let id = session.renamingLayerID, let row = next.firstIndex(where: { $0.id == id }) {
                table.scrollRowToVisible(row)
                DispatchQueue.main.async {
                    (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? LayerCell)?.beginRenaming()
                }
            }
        }

        func layer(for row: Int) -> ImageLayer? {
            guard rows.indices.contains(row) else { return nil }
            return rows[row]
        }

        func contextMenu(for row: Int) -> NSMenu? {
            guard rows.indices.contains(row) else { return nil }
            if session.selectedLayerIDs.isEmpty {
                session.selectLayer(rows[row].id)
            }
            let menu = NSMenu()

            // 1. Duplicate Layer
            let duplicateItem = NSMenuItem(title: "Duplicate Layer", action: #selector(duplicateLayerAction), keyEquivalent: "")
            duplicateItem.target = self
            duplicateItem.isEnabled = validateMenuItem(duplicateItem)
            menu.addItem(duplicateItem)

            // 2. Rename…
            let renameItem = NSMenuItem(title: "Rename…", action: #selector(renameLayerAction), keyEquivalent: "")
            renameItem.target = self
            renameItem.isEnabled = validateMenuItem(renameItem)
            menu.addItem(renameItem)

            // 3. Delete Layer / Delete Selected Layers
            let deleteTitle: String
            if session.isMaskSelected && session.activeLayer?.mask != nil {
                deleteTitle = "Delete Mask"
            } else if session.selectedLayerIDs.count > 1 {
                deleteTitle = "Delete Selected Layers"
            } else {
                deleteTitle = "Delete Layer"
            }
            let deleteItem = NSMenuItem(title: deleteTitle, action: #selector(deleteLayerAction), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.isEnabled = validateMenuItem(deleteItem)
            menu.addItem(deleteItem)

            menu.addItem(NSMenuItem.separator())

            // 4. Create Clipping Mask / Release Clipping Mask
            let clippingTitle = session.activeLayer?.maskSourceID != nil ? "Release Clipping Mask" : "Create Clipping Mask"
            let clippingItem = NSMenuItem(title: clippingTitle, action: #selector(toggleClippingMaskAction), keyEquivalent: "")
            clippingItem.target = self
            clippingItem.isEnabled = validateMenuItem(clippingItem)
            menu.addItem(clippingItem)

            // 5. Group Selected Layers
            let groupItem = NSMenuItem(title: "Group Selected Layers", action: #selector(groupSelectedLayersAction), keyEquivalent: "")
            groupItem.target = self
            groupItem.isEnabled = validateMenuItem(groupItem)
            menu.addItem(groupItem)

            // A folder right-clicked can be ungrouped: its layers stay where they are, and the folder goes.
            if rows[row].isGroup {
                let ungroupItem = NSMenuItem(title: "Ungroup Layers", action: #selector(ungroupLayersAction), keyEquivalent: "")
                ungroupItem.target = self
                ungroupItem.isEnabled = validateMenuItem(ungroupItem)
                menu.addItem(ungroupItem)
            }

            // 6. Move Out of Folder
            let moveOutItem = NSMenuItem(title: "Move Out of Folder", action: #selector(moveOutOfFolderAction), keyEquivalent: "")
            moveOutItem.target = self
            moveOutItem.isEnabled = validateMenuItem(moveOutItem)
            menu.addItem(moveOutItem)

            // 7. Merge Down / Merge Layers / Merge Group
            let mergeItem = NSMenuItem(title: session.mergeTitle, action: #selector(mergeLayersAction), keyEquivalent: "")
            mergeItem.target = self
            mergeItem.isEnabled = validateMenuItem(mergeItem)
            menu.addItem(mergeItem)

            menu.addItem(NSMenuItem.separator())

            // 8. Add Mask >
            let addMaskItem = NSMenuItem(title: "Add Mask", action: nil, keyEquivalent: "")
            let addMaskSubmenu = NSMenu(title: "Add Mask")
            let revealAllItem = NSMenuItem(title: "Reveal All (White)", action: #selector(addWhiteMaskAction), keyEquivalent: "")
            revealAllItem.target = self
            revealAllItem.isEnabled = validateMenuItem(revealAllItem)
            addMaskSubmenu.addItem(revealAllItem)
            let hideAllItem = NSMenuItem(title: "Hide All (Black)", action: #selector(addBlackMaskAction), keyEquivalent: "")
            hideAllItem.target = self
            hideAllItem.isEnabled = validateMenuItem(hideAllItem)
            addMaskSubmenu.addItem(hideAllItem)
            addMaskItem.submenu = addMaskSubmenu
            addMaskItem.isEnabled = session.canEditMask && session.activeLayer?.mask == nil
            menu.addItem(addMaskItem)

            // 9. Enable Mask / Disable Mask
            let toggleMaskTitle = session.activeLayer?.mask?.isEnabled == false ? "Enable Mask" : "Disable Mask"
            let toggleMaskItem = NSMenuItem(title: toggleMaskTitle, action: #selector(toggleMaskAction), keyEquivalent: "")
            toggleMaskItem.target = self
            toggleMaskItem.isEnabled = validateMenuItem(toggleMaskItem)
            menu.addItem(toggleMaskItem)

            // 10. Delete Mask
            let deleteMaskItem = NSMenuItem(title: "Delete Mask", action: #selector(deleteMaskAction), keyEquivalent: "")
            deleteMaskItem.target = self
            deleteMaskItem.isEnabled = validateMenuItem(deleteMaskItem)
            menu.addItem(deleteMaskItem)

            // 11. Link Mask / Unlink Mask
            let linkMaskTitle = session.activeLayer?.mask?.isLinked == false ? "Link Mask" : "Unlink Mask"
            let linkMaskItem = NSMenuItem(title: linkMaskTitle, action: #selector(toggleMaskLinkAction), keyEquivalent: "")
            linkMaskItem.target = self
            linkMaskItem.isEnabled = validateMenuItem(linkMaskItem)
            menu.addItem(linkMaskItem)

            menu.addItem(NSMenuItem.separator())

            // 12. Hide Layer / Show Layer
            let visibilityTitle = session.activeLayer?.isVisible == false ? "Show Layer" : "Hide Layer"
            let visibilityItem = NSMenuItem(title: visibilityTitle, action: #selector(toggleVisibilityAction), keyEquivalent: "")
            visibilityItem.target = self
            visibilityItem.isEnabled = validateMenuItem(visibilityItem)
            menu.addItem(visibilityItem)

            return menu
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            switch menuItem.action {
            case #selector(duplicateLayerAction):
                return session.canEditLayers && session.activeLayer != nil
            case #selector(renameLayerAction):
                return session.canEditLayers && session.activeLayer != nil && session.selectedLayerIDs.count == 1
            case #selector(deleteLayerAction):
                return session.canEditLayers && session.activeLayer != nil
            case #selector(toggleClippingMaskAction):
                return session.activeLayerID.map { session.canToggleClippingMask($0) } ?? false
            case #selector(groupSelectedLayersAction):
                return session.canEditLayers && session.document != nil && (session.document?.layers.count ?? 0) < 10_000 && !session.selectedLayerIDs.isEmpty
            case #selector(ungroupLayersAction):
                return session.canUngroupLayers
            case #selector(moveOutOfFolderAction):
                return session.canEditLayers && session.activeLayer?.parentID != nil
            case #selector(mergeLayersAction):
                return session.canMergeLayers
            case #selector(addWhiteMaskAction), #selector(addBlackMaskAction):
                return session.canEditMask && session.activeLayer?.mask == nil
            case #selector(toggleMaskAction):
                return session.canEditMask && session.activeLayer?.mask != nil
            case #selector(deleteMaskAction):
                return session.canEditMask && session.activeLayer?.mask != nil
            case #selector(toggleMaskLinkAction):
                return session.canEditLayers && session.activeLayer?.mask != nil && session.activeLayer?.isGroup == false && session.activeLayer?.adjustment == nil
            case #selector(toggleVisibilityAction):
                return session.canEditLayers && session.activeLayer != nil
            default:
                if menuItem.submenu != nil && menuItem.title == "Add Mask" {
                    return session.canEditMask && session.activeLayer?.mask == nil
                }
                return true
            }
        }

        @objc func duplicateLayerAction(_ sender: Any?) {
            session.duplicateActiveLayer()
        }

        @objc func renameLayerAction(_ sender: Any?) {
            guard session.canEditLayers, let id = session.activeLayerID else { return }
            session.renamingLayerID = id
        }

        @objc func deleteLayerAction(_ sender: Any?) {
            session.deleteLayerOrMask()
        }

        @objc func toggleClippingMaskAction(_ sender: Any?) {
            if let id = session.activeLayerID { session.toggleClippingMask(id) }
        }

        @objc func groupSelectedLayersAction(_ sender: Any?) {
            session.groupSelectedLayers()
        }

        @objc func ungroupLayersAction(_ sender: Any?) {
            session.ungroupLayers()
        }

        @objc func moveOutOfFolderAction(_ sender: Any?) {
            session.moveActiveLayerOutOfGroup()
        }

        @objc func mergeLayersAction(_ sender: Any?) {
            session.mergeLayers()
        }

        @objc func addWhiteMaskAction(_ sender: Any?) {
            guard let id = session.activeLayerID else { return }
            session.selectLayerTarget(id, mask: false)
            session.addMask(revealing: true)
        }

        @objc func addBlackMaskAction(_ sender: Any?) {
            guard let id = session.activeLayerID else { return }
            session.selectLayerTarget(id, mask: false)
            session.addMask(revealing: false)
        }

        @objc func toggleMaskAction(_ sender: Any?) {
            guard let id = session.activeLayerID else { return }
            session.selectLayerTarget(id, mask: false)
            session.toggleLayerMask()
        }

        @objc func deleteMaskAction(_ sender: Any?) {
            guard let id = session.activeLayerID else { return }
            session.selectLayerTarget(id, mask: false)
            session.deleteLayerMask()
        }

        @objc func toggleMaskLinkAction(_ sender: Any?) {
            if let id = session.activeLayerID { session.toggleMaskLink(id) }
        }

        @objc func toggleVisibilityAction(_ sender: Any?) {
            guard let id = session.activeLayerID else { return }
            session.toggleLayerVisibility(id)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            52 + CGFloat(rows[row].effects?.kinds.count ?? 0) * 24
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("layerCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LayerCell ?? LayerCell()
            cell.identifier = identifier
            cell.configure(rows[row], enabled: editingEnabled, session: session, depth: rowDetails[rows[row].id]?.depth ?? 0, visible: rowDetails[rows[row].id]?.visible ?? true)
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !synchronizing, let table = notification.object as? NSTableView else { return }
            let selected = table.selectedRowIndexes.filter { rows.indices.contains($0) }
            let ids = Set(selected.map { rows[$0].id })
            let primary = selected.contains(table.clickedRow) ? rows[table.clickedRow].id : selected.first.map { rows[$0].id }
            session.selectLayers(ids, primary: primary)
        }
