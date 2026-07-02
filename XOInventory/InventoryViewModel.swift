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
    @Published var srs: [SR] = []
    @Published var totalDiskByVM: [String: Int64] = [:]  // uuid -> bytes
    @Published var isLoading: Bool = false
    @Published var statusMessage: String = ""
    @Published var errorMessage: String?
    @Published var lastRefreshed: Date?

    /// Host UUID, or nil for "all". Persisted across launches; refresh() prunes
    /// it if the stored host no longer exists on the connected XO instance.
    @Published var hostFilter: String? = UserDefaults.standard.string(forKey: hostFilterKey) {
        didSet {
            if let f = hostFilter {
                UserDefaults.standard.set(f, forKey: Self.hostFilterKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.hostFilterKey)
            }
        }
    }
    private static let hostFilterKey = "XOInventory.hostFilter"

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

    /// Map host UUID → count of VMs residing on that host, computed from the
    /// VM list. Includes all VMs (running and halted) whose `$container` is
    /// a host UUID.
    var vmCountByHost: [String: Int] {
        var counts: [String: Int] = [:]
        let hostUUIDs = Set(hosts.map(\.uuid))
        for vm in vms {
            guard let container = vm.host, hostUUIDs.contains(container) else { continue }
            counts[container, default: 0] += 1
        }
        return counts
    }

    /// Disk info per host: local = sum of local SRs attached to this host,
    /// total = local + shared SRs in the pool. Values are in bytes.
    struct HostDisk {
        var localTotalBytes: Int64 = 0
        var localUsedBytes: Int64 = 0
        var sharedTotalBytes: Int64 = 0
        var sharedUsedBytes: Int64 = 0

        var totalBytes: Int64 { localTotalBytes + sharedTotalBytes }
        var totalUsedBytes: Int64 { localUsedBytes + sharedUsedBytes }

        /// 0...1 fraction. Nil when total is 0 or unknown.
        var usageFraction: Double? {
            guard totalBytes > 0 else { return nil }
            return min(1.0, Double(totalUsedBytes) / Double(totalBytes))
        }
    }

    /// Compute per-host disk rollup from the SR list. Local SRs attach to
    /// exactly one host via $container; shared SRs attach to the pool, so
    /// they contribute to every host's "total" number.
    var diskByHost: [String: HostDisk] {
        let hostUUIDs = Set(hosts.map(\.uuid))
        var sharedTotal: Int64 = 0
        var sharedUsed: Int64 = 0
        var perHost: [String: HostDisk] = [:]

        for sr in srs where sr.isUsableStorage {
            if sr.shared {
                sharedTotal += sr.size
                sharedUsed += sr.physicalUsage
            } else if hostUUIDs.contains(sr.container) {
                var d = perHost[sr.container, default: HostDisk()]
                d.localTotalBytes += sr.size
                d.localUsedBytes += sr.physicalUsage
                perHost[sr.container] = d
            }
        }

        // Fold shared totals into every host's rollup.
        for uuid in hostUUIDs {
            var d = perHost[uuid, default: HostDisk()]
            d.sharedTotalBytes = sharedTotal
            d.sharedUsedBytes = sharedUsed
            perHost[uuid] = d
        }
        return perHost
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
        srs = []
        totalDiskByVM = [:]
        // hostFilter is intentionally kept: reconnecting to the same XO instance
        // restores it, and refresh() prunes it if the host doesn't exist.
        statusMessage = ""
        lastRefreshed = nil
    }

    func refresh() async {
        guard let client else { return }
        errorMessage = nil
        isLoading = true
        statusMessage = "Fetching hosts, VMs, and storage…"
        defer { isLoading = false }

        do {
            // Three fetches in parallel — they don't depend on each other.
            async let hostsTask = client.fetchHosts()
            async let vmsTask = client.fetchVMs()
            async let srsTask = client.fetchSRs()
            let (fetchedHosts, fetched, fetchedSRs) = try await (hostsTask, vmsTask, srsTask)

            self.hosts = fetchedHosts.sorted {
                $0.nameLabel.localizedCaseInsensitiveCompare($1.nameLabel) == .orderedAscending
            }
            self.srs = fetchedSRs

            // Sort: running first, then by name.
            self.vms = fetched.sorted { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning && !rhs.isRunning }
                return lhs.nameLabel.localizedCaseInsensitiveCompare(rhs.nameLabel) == .orderedAscending
            }

            // Prune the filter if it points at a host that no longer exists.
            if let f = hostFilter, !self.hosts.contains(where: { $0.uuid == f }) {
                self.hostFilter = nil
            }

            statusMessage = "Loaded \(fetched.count) VM\(fetched.count == 1 ? "" : "s"). Summing VM disks…"
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
