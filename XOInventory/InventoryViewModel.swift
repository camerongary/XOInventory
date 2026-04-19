//
//  InventoryViewModel.swift
//  XOInventory
//

import Foundation
import SwiftUI

/// Holds VM list + UI state. MainActor because everything it publishes is consumed by the UI.
@MainActor
final class InventoryViewModel: ObservableObject {
    @Published var vms: [VM] = []
    @Published var hosts: [Host] = []
    @Published var totalDiskByVM: [String: Int64] = [:]  // uuid -> bytes
    @Published var isLoading: Bool = false
    @Published var statusMessage: String = ""
    @Published var errorMessage: String?
    @Published var lastRefreshed: Date?
    @Published var hostFilter: String? = nil              // host UUID, or nil for "all"

    private var client: XOClient?

    /// VMs filtered by the selected host, used by the inventory UI.
    var filteredVMs: [VM] {
        guard let hostUUID = hostFilter else { return vms }
        return vms.filter { $0.host == hostUUID }
    }

    /// Map host UUID → host name, for displaying the VM's host in labels.
    var hostNamesByUUID: [String: String] {
        Dictionary(uniqueKeysWithValues: hosts.map { ($0.uuid, $0.nameLabel) })
    }

    func connect(using connection: XOConnection) async {
        errorMessage = nil
        isLoading = true
        statusMessage = "Connecting…"
        defer { isLoading = false }

        let client = XOClient(connection: connection)
        do {
            try await client.probe()
            self.client = client
            statusMessage = "Connected. Loading VMs…"
            await refresh()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusMessage = ""
            self.client = nil
        }
    }

    func disconnect() {
        client = nil
        vms = []
        hosts = []
        totalDiskByVM = [:]
        hostFilter = nil
        statusMessage = ""
        lastRefreshed = nil
    }

    func refresh() async {
        guard let client else { return }
        errorMessage = nil
        isLoading = true
        statusMessage = "Fetching hosts and VMs…"
        defer { isLoading = false }

        do {
            // Hosts are small; fetch in parallel with VMs.
            async let hostsTask = client.fetchHosts()
            async let vmsTask = client.fetchVMs()
            let (fetchedHosts, fetched) = try await (hostsTask, vmsTask)

            self.hosts = fetchedHosts.sorted {
                $0.nameLabel.localizedCaseInsensitiveCompare($1.nameLabel) == .orderedAscending
            }

            // Sort: running first, then by name.
            self.vms = fetched.sorted { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning && !rhs.isRunning }
                return lhs.nameLabel.localizedCaseInsensitiveCompare(rhs.nameLabel) == .orderedAscending
            }

            // Prune the filter if it points at a host that no longer exists.
            if let f = hostFilter, !self.hosts.contains(where: { $0.uuid == f }) {
                self.hostFilter = nil
            }

            statusMessage = "Loaded \(fetched.count) VM\(fetched.count == 1 ? "" : "s"). Summing disks…"
            await loadDiskSizes(for: fetched, using: client)
            lastRefreshed = Date()
            statusMessage = "Loaded \(self.hosts.count) host\(self.hosts.count == 1 ? "" : "s"), \(fetched.count) VM\(fetched.count == 1 ? "" : "s")."
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusMessage = ""
        }
    }

    // MARK: - Disk rollup

    private func loadDiskSizes(for vms: [VM], using client: XOClient) async {
        // Parallelize with a modest concurrency cap so we don't hammer XO.
        await withTaskGroup(of: (String, Int64).self) { group in
            let cap = 6
            var iterator = vms.makeIterator()
            var running = 0

            func spawnNext() {
                guard let vm = iterator.next() else { return }
                running += 1
                group.addTask {
                    let bytes = await client.fetchTotalDiskBytes(vmUUID: vm.uuid)
                    return (vm.uuid, bytes)
                }
            }

            for _ in 0..<cap { spawnNext() }

            for await (uuid, bytes) in group {
                self.totalDiskByVM[uuid] = bytes
                running -= 1
                spawnNext()
            }
        }
    }

    // MARK: - Export

    func csvRepresentation() -> String {
        var lines: [String] = []
        lines.append("Name,UUID,Power State,vCPUs,Memory,IP Address,All IPs,OS,Total Disk,Description")
        for vm in vms {
            let disk = totalDiskByVM[vm.uuid] ?? 0
            let diskStr = disk > 0
                ? VM.byteFormatter.string(fromByteCount: disk)
                : "—"
            let row: [String] = [
                vm.nameLabel,
                vm.uuid,
                vm.powerState,
                vm.cpuDisplay,
                vm.memoryDisplay,
                vm.ipDisplay,
                vm.otherIpAddresses.joined(separator: "; "),
                vm.os ?? "",
                diskStr,
                vm.nameDescription ?? ""
            ]
            lines.append(row.map(csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }
}

extension VM {
    var isRunning: Bool { powerState.caseInsensitiveCompare("Running") == .orderedSame }
}
