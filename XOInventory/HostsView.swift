//
//  HostsView.swift
//  XOInventory
//
//  Shows hypervisors in the pool: name, address, CPU, memory utilization,
//  version, and VMs running on each.
//

import SwiftUI

struct HostsView: View {
    @ObservedObject var viewModel: InventoryViewModel

    @State private var selection: Host.ID?
    @State private var sortOrder: [KeyPathComparator<Host>] = [
        KeyPathComparator(\.nameLabel)
    ]

    private var selectedHost: Host? {
        guard let id = selection else { return nil }
        return viewModel.hosts.first { $0.uuid == id }
    }

    private var sortedHosts: [Host] {
        viewModel.hosts.sorted(using: sortOrder)
    }

    var body: some View {
        HSplitView {
            table
                .frame(minWidth: 560)

            if let host = selectedHost {
                HostDetailView(
                    host: host,
                    vmCount: viewModel.vmCountByHost[host.uuid] ?? 0,
                    disk: viewModel.diskByHost[host.uuid]
                )
                    .frame(minWidth: 280, idealWidth: 340)
            } else {
                VStack {
                    Spacer()
                    Text("Select a host to see details")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(minWidth: 280, idealWidth: 340)
            }
        }
    }

    // MARK: - Table

    private var table: some View {
        // Snapshot these once per render so table closures don't recompute.
        let vmCounts = viewModel.vmCountByHost
        let diskMap = viewModel.diskByHost

        return Table(sortedHosts, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.nameLabel) { host in
                Text(host.nameLabel).fontWeight(.semibold)
            }
            .width(min: 140, ideal: 180)

            TableColumn("Address") { host in
                Text(host.address ?? "—")
                    .monospaced()
                    .foregroundStyle(host.address == nil ? Color.secondary : .primary)
            }
            .width(min: 100, ideal: 140)

            TableColumn("CPU") { host in
                Text(host.cpuDisplay)
                    .monospacedDigit()
            }
            .width(min: 100, ideal: 140)

            TableColumn("Memory") { host in
                HostMemoryCell(host: host)
            }
            .width(min: 140, ideal: 180, max: 220)

            TableColumn("Disk") { host in
                HostDiskCell(disk: diskMap[host.uuid])
            }
            .width(min: 140, ideal: 180, max: 220)

            TableColumn("VMs") { host in
                Text("\(vmCounts[host.uuid] ?? 0)")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .width(min: 50, ideal: 55, max: 70)

            TableColumn("Version") { host in
                Text(host.version ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        }
    }
}

// MARK: - Memory cell with bar

private struct HostMemoryCell: View {
    let host: Host

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("\(host.memoryUsageDisplay) / \(host.memoryTotalDisplay)")
                    .font(.callout)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if let fraction = host.memoryUsageFraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.18))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor(for: fraction))
                            .frame(width: geo.size.width * CGFloat(fraction))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.vertical, 2)
    }

    private func barColor(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.7:  return .green
        case ..<0.9:  return .orange
        default:      return .red
        }
    }
}

// MARK: - Disk cell with bar

/// Displays Local/Total usage for a host. If there are no shared SRs, the
/// label drops the "Local / Total" distinction and just shows one pair.
private struct HostDiskCell: View {
    let disk: InventoryViewModel.HostDisk?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayText)
                .font(.callout)
                .monospacedDigit()
                .lineLimit(1)

            if let fraction = disk?.usageFraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.18))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor(for: fraction))
                            .frame(width: geo.size.width * CGFloat(fraction))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.vertical, 2)
    }

    /// When shared storage exists, show "local / total". When all storage is
    /// local (or all shared), show just one used / total pair.
    private var displayText: String {
        guard let d = disk, d.totalBytes > 0 else { return "—" }
        let fmt = VM.byteFormatter
        let hasLocal = d.localTotalBytes > 0
        let hasShared = d.sharedTotalBytes > 0

        if hasLocal && hasShared {
            return "\(fmt.string(fromByteCount: d.localTotalBytes)) / \(fmt.string(fromByteCount: d.totalBytes))"
        }
        return "\(fmt.string(fromByteCount: d.totalUsedBytes)) / \(fmt.string(fromByteCount: d.totalBytes))"
    }

    private func barColor(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.7:  return .green
        case ..<0.9:  return .orange
        default:      return .red
        }
    }
}

// MARK: - Detail pane

struct HostDetailView: View {
    let host: Host
    let vmCount: Int
    let disk: InventoryViewModel.HostDisk?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(host.nameLabel)
                            .font(.title3).bold()
                            .lineLimit(2)
                        Spacer()
                        PowerStatePill(state: host.powerState ?? "Unknown")
                    }
                    if let desc = host.nameDescription, !desc.isEmpty {
                        Text(desc)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                section("Hardware") {
                    row("CPU", host.cpuDisplay)
                    if let model = host.cpuModel, !model.isEmpty {
                        row("CPU Model", model, wrap: true)
                    }
                    row("Memory", "\(host.memoryUsageDisplay) of \(host.memoryTotalDisplay)")
                    if let frac = host.memoryUsageFraction {
                        row("Memory Used", String(format: "%.0f%%", frac * 100))
                    }
                }

                if let d = disk, d.totalBytes > 0 {
                    section("Storage") {
                        let fmt = VM.byteFormatter
                        if d.localTotalBytes > 0 {
                            row("Local",
                                "\(fmt.string(fromByteCount: d.localUsedBytes)) of \(fmt.string(fromByteCount: d.localTotalBytes))")
                        }
                        if d.sharedTotalBytes > 0 {
                            row("Shared (pool)",
                                "\(fmt.string(fromByteCount: d.sharedUsedBytes)) of \(fmt.string(fromByteCount: d.sharedTotalBytes))")
                        }
                        row("Total Available",
                            fmt.string(fromByteCount: d.totalBytes))
                        if let frac = d.usageFraction {
                            row("Total Used", String(format: "%.0f%%", frac * 100))
                        }
                    }
                }

                section("Network") {
                    row("Address", host.address ?? "—", mono: true, selectable: true)
                }

                section("Status") {
                    row("Power State", host.powerState ?? "—")
                    if let enabled = host.enabled {
                        row("Scheduling", enabled ? "Enabled" : "Disabled")
                    }
                    row("Version", host.version ?? "—")
                    row("Resident VMs", "\(vmCount)")
                }

                section("System") {
                    row("UUID", host.uuid, mono: true, selectable: true)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String,
                     mono: Bool = false, selectable: Bool = false, wrap: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Group {
                if selectable {
                    Text(value).textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .font(.callout)
            .if(mono) { $0.monospaced() }
            .if(!wrap) { $0.lineLimit(1).truncationMode(.tail) }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
