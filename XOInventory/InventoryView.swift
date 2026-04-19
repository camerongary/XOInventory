//
//  InventoryView.swift
//  XOInventory
//

import SwiftUI
import UniformTypeIdentifiers

struct InventoryView: View {
    @ObservedObject var viewModel: InventoryViewModel
    var hostDisplay: String
    var onDisconnect: () -> Void

    @State private var search: String = ""
    @State private var sortOrder: [KeyPathComparator<VMRow>] = [
        KeyPathComparator(\.isRunningInt, order: .reverse),
        KeyPathComparator(\.name)
    ]
    @State private var selection: VM.ID?
    @State private var showExporter = false
    @State private var showPDFExporter = false
    @State private var selectedTab: Tab = .vms

    enum Tab: String, CaseIterable, Identifiable {
        case vms = "VMs"
        case hosts = "Hosts"
        var id: String { rawValue }
    }

    private var rows: [VMRow] {
        // Start with the host-filtered set from the view model.
        let filteredByHost = viewModel.filteredVMs
        let mapped = filteredByHost.map { vm in
            VMRow(vm: vm, diskBytes: viewModel.totalDiskByVM[vm.uuid] ?? 0)
        }
        let filtered: [VMRow]
        if search.isEmpty {
            filtered = mapped
        } else {
            let q = search.lowercased()
            filtered = mapped.filter {
                $0.name.lowercased().contains(q) ||
                $0.ip.lowercased().contains(q) ||
                $0.powerState.lowercased().contains(q) ||
                ($0.vm.os ?? "").lowercased().contains(q)
            }
        }
        return filtered.sorted(using: sortOrder)
    }

    private var selectedVM: VM? {
        guard let id = selection else { return nil }
        return viewModel.vms.first { $0.uuid == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            // Tab switcher
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tabLabel(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: 360)

            Divider()

            // Tab content
            Group {
                switch selectedTab {
                case .vms:
                    vmsPane
                case .hosts:
                    HostsView(viewModel: viewModel)
                }
            }

            Divider()
            statusBar
        }
        .fileExporter(
            isPresented: $showExporter,
            document: CSVDocument(text: viewModel.csvRepresentation()),
            contentType: .commaSeparatedText,
            defaultFilename: "xcp-ng-inventory-\(dateString()).csv"
        ) { result in
            if case .failure(let err) = result {
                viewModel.errorMessage = err.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showPDFExporter,
            document: PDFDocumentFile(data: PDFReport.build(
                vms: viewModel.filteredVMs,
                diskByVM: viewModel.totalDiskByVM,
                hostDisplay: hostDisplay
            )),
            contentType: .pdf,
            defaultFilename: "xcp-ng-inventory-\(dateString()).pdf"
        ) { result in
            if case .failure(let err) = result {
                viewModel.errorMessage = err.localizedDescription
            }
        }
    }

    private func tabLabel(_ tab: Tab) -> String {
        switch tab {
        case .vms:
            let n = viewModel.filteredVMs.count
            return "VMs (\(n))"
        case .hosts:
            return "Hosts (\(viewModel.hosts.count))"
        }
    }

    // MARK: - VMs pane (table + detail)

    private var vmsPane: some View {
        HSplitView {
            VStack(spacing: 0) {
                vmsFilterBar
                Divider()
                table
            }
            .frame(minWidth: 640)

            if let vm = selectedVM {
                VMDetailView(vm: vm, diskBytes: viewModel.totalDiskByVM[vm.uuid] ?? 0)
                    .frame(minWidth: 280, idealWidth: 320)
            } else {
                VStack {
                    Spacer()
                    Text("Select a VM to see details")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(minWidth: 280, idealWidth: 320)
            }
        }
    }

    // MARK: - VMs filter bar (search + host picker)

    private var vmsFilterBar: some View {
        HStack(spacing: 10) {
            // Host filter
            Menu {
                Button {
                    viewModel.hostFilter = nil
                } label: {
                    HStack {
                        if viewModel.hostFilter == nil {
                            Image(systemName: "checkmark")
                        }
                        Text("All hosts")
                    }
                }
                if !viewModel.hosts.isEmpty {
                    Divider()
                    ForEach(viewModel.hosts) { host in
                        Button {
                            viewModel.hostFilter = host.uuid
                        } label: {
                            HStack {
                                if viewModel.hostFilter == host.uuid {
                                    Image(systemName: "checkmark")
                                }
                                Text(host.nameLabel)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "server.rack")
                    Text(hostFilterLabel)
                        .lineLimit(1)
                }
            }
            .fixedSize()

            TextField("Search name, IP, OS…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            Spacer()
        }
        .padding(10)
    }

    private var hostFilterLabel: String {
        if let uuid = viewModel.hostFilter,
           let name = viewModel.hostNamesByUUID[uuid] {
            return name
        }
        return "All hosts"
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(hostDisplay)
                    .font(.headline)
                if let last = viewModel.lastRefreshed {
                    Text("Last refresh: \(last.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isLoading)
            .keyboardShortcut("r", modifiers: .command)

            Menu {
                Button {
                    showExporter = true
                } label: {
                    Label("Export as CSV…", systemImage: "tablecells")
                }
                Button {
                    showPDFExporter = true
                } label: {
                    Label("Export as PDF…", systemImage: "doc.richtext")
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .disabled(viewModel.vms.isEmpty)

            Button {
                onDisconnect()
            } label: {
                Label("Switch Host", systemImage: "arrow.left.arrow.right")
            }
            .help("Return to the host picker")
        }
        .padding(10)
    }

    // MARK: - Table

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                Text(row.name)
                    .fontWeight(row.vm.isRunning ? .semibold : .regular)
            }
            .width(min: 140, ideal: 200)

            TableColumn("State", value: \.powerState) { row in
                PowerStatePill(state: row.powerState)
            }
            .width(min: 80, ideal: 90)

            TableColumn("IP Address", value: \.ip) { row in
                Text(row.ip).monospaced()
            }
            .width(min: 100, ideal: 140)

            TableColumn("vCPUs", value: \.cpus) { row in
                Text(row.vm.cpuDisplay)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 60)

            TableColumn("Memory", value: \.memoryBytes) { row in
                Text(row.vm.memoryDisplay)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Disk", value: \.diskBytes) { row in
                Text(row.diskBytes > 0
                     ? VM.byteFormatter.string(fromByteCount: row.diskBytes)
                     : "—")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)

            TableColumn("OS") { row in
                Text(row.vm.os ?? "—")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 160)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            if viewModel.isLoading {
                ProgressView().controlSize(.small)
            }
            Text(viewModel.isLoading
                 ? viewModel.statusMessage
                 : statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if let err = viewModel.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var statusText: String {
        switch selectedTab {
        case .vms:
            let total = viewModel.filteredVMs.count
            let plural = total == 1 ? "" : "s"
            if rows.count < total {
                return "\(rows.count) of \(total) VM\(plural)"
            }
            return "\(total) VM\(plural)"
        case .hosts:
            let n = viewModel.hosts.count
            return "\(n) host\(n == 1 ? "" : "s")"
        }
    }

    private func dateString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmm"
        return df.string(from: Date())
    }
}

// MARK: - Row wrapper for Table sorting

struct VMRow: Identifiable {
    let vm: VM
    let diskBytes: Int64
    var id: String { vm.uuid }
    var name: String { vm.nameLabel }
    var powerState: String { vm.powerState }
    var ip: String { vm.ipDisplay }
    var cpus: Int { vm.cpus ?? 0 }
    var memoryBytes: Int64 { vm.memoryBytes ?? 0 }
    var isRunningInt: Int { vm.isRunning ? 1 : 0 }
}

// MARK: - Power state pill

struct PowerStatePill: View {
    let state: String
    var body: some View {
        Text(state)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
    private var color: Color {
        switch state.lowercased() {
        case "running": return .green
        case "halted": return .secondary
        case "paused", "suspended": return .orange
        default: return .secondary
        }
    }
}

// MARK: - CSV document

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let s = String(data: data, encoding: .utf8) {
            self.text = s
        } else {
            self.text = ""
        }
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - PDF document

struct PDFDocumentFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
