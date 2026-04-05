import AppKit

class HistoryWindow: NSWindow {
    private let store: HistoryStore
    private var tableView: NSTableView!
    private var searchField: NSSearchField!
    private var filteredEntries: [TranscriptionEntry] = []
    private var searchTerm: String = ""

    init(store: HistoryStore) {
        self.store = store
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Transcription History"
        minSize = NSSize(width: 400, height: 300)
        center()
        buildUI()
        refreshTable()
    }

    private func buildUI() {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 500))

        // Search field
        searchField = NSSearchField(frame: NSRect(x: 16, y: 460, width: 470, height: 28))
        searchField.placeholderString = "Search history..."
        searchField.target = self
        searchField.action = #selector(searchChanged)
        contentView.addSubview(searchField)

        // Clear all button
        let clearBtn = NSButton(title: "Clear All", target: self, action: #selector(clearAll))
        clearBtn.frame = NSRect(x: 500, y: 460, width: 104, height: 28)
        clearBtn.bezelStyle = .rounded
        contentView.addSubview(clearBtn)

        // Table with scroll view
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 40, width: 620, height: 416))
        let tv = NSTableView()
        tv.autoresizingMask = [.width, .height]
        tv.allowsColumnReordering = false
        tv.usesAlternatingRowBackgroundColors = true

        let col1 = NSTableColumn(identifier: .init("text"))
        col1.title = "Transcription"
        col1.minWidth = 370
        tv.addTableColumn(col1)

        let col2 = NSTableColumn(identifier: .init("date"))
        col2.title = "Date"
        col2.minWidth = 80
        col2.maxWidth = 140
        tv.addTableColumn(col2)

        tv.dataSource = self
        tv.delegate = self
        tv.doubleAction = #selector(doubleClickCopy)
        tv.target = self
        scrollView.documentView = tv
        contentView.addSubview(scrollView)

        // Delete selected button at bottom
        let deleteBtn = NSButton(title: "Delete Selected", target: self, action: #selector(deleteSelected))
        deleteBtn.frame = NSRect(x: 16, y: 8, width: 130, height: 28)
        deleteBtn.bezelStyle = .rounded
        contentView.addSubview(deleteBtn)

        // Count label
        let countLabel = NSTextField(labelWithString: "")
        countLabel.frame = NSRect(x: 470, y: 8, width: 134, height: 28)
        countLabel.alignment = .right
        countLabel.font = NSFont.systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        countLabel.identifier = .init("countLabel")
        contentView.addSubview(countLabel)

        tableView = tv
        self.contentView = contentView
    }

    @objc func searchChanged() {
        searchTerm = searchField.stringValue
        refreshTable()
    }

    @objc func clearAll() {
        store.clearAll()
        refreshTable()
    }

    @objc func deleteSelected() {
        let indices = tableView.selectedRowIndexes.sorted()
        let toDelete = indices.reversed().compactMap { idx -> TranscriptionEntry? in
            guard idx < filteredEntries.count else { return nil }
            return filteredEntries[idx]
        }
        for entry in toDelete {
            store.deleteEntry(entry)
        }
        refreshTable()
    }

    @objc func doubleClickCopy() {
        let row = tableView.clickedRow
        guard row >= 0, row < filteredEntries.count else { return }
        let entry = filteredEntries[row]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    func refreshTable() {
        filteredEntries = store.entries.filter {
            searchTerm.isEmpty || $0.text.localizedCaseInsensitiveContains(searchTerm)
        }
        tableView.reloadData()

        // Update count label
        if let contentView = contentView {
            for subview in contentView.subviews {
                if subview.identifier == .init("countLabel") {
                    (subview as? NSTextField)?.stringValue = "\(filteredEntries.count) entr\(filteredEntries.count == 1 ? "y" : "ies")"
                    break
                }
            }
        }
    }
}

// MARK: - Table Data Source & Delegate

extension HistoryWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filteredEntries[row]

        if tableColumn?.identifier == .init("text") {
            if let cell = tableView.makeView(withIdentifier: .init("textCell"), owner: nil) as? NSTextField {
                cell.stringValue = entry.text
                return cell
            }
            let cell = NSTextField(wrappingLabelWithString: entry.text)
            cell.identifier = .init("textCell")
            cell.isEditable = false
            cell.isSelectable = true
            cell.isBordered = false
            cell.drawsBackground = false
            cell.font = NSFont.systemFont(ofSize: 13)
            return cell
        } else {
            if let cell = tableView.makeView(withIdentifier: .init("dateCell"), owner: nil) as? NSTextField {
                let fmt = DateFormatter()
                fmt.dateFormat = "MMM d, HH:mm"
                cell.stringValue = fmt.string(from: entry.date)
                return cell
            }
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d, HH:mm"
            let cell = NSTextField(labelWithString: fmt.string(from: entry.date))
            cell.identifier = .init("dateCell")
            cell.isEditable = false
            cell.isBordered = false
            cell.drawsBackground = false
            cell.font = NSFont.systemFont(ofSize: 11)
            cell.textColor = .secondaryLabelColor
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let entry = filteredEntries[row]
        // Estimate height based on text length
        let width: CGFloat = 370
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        let rect = (entry.text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return max(40, rect.height + 16)
    }
}
