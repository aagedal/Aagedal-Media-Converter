// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin
import os

struct AV2MemorySnapshot: Sendable {
    enum Pressure: Sendable { case normal, warning, critical }
    let physicalBytes: UInt64
    let availableBytes: UInt64
    let pressure: Pressure

    /// An estimate, not a promise about avmenc's peak allocation. Includes decoder,
    /// reference/lookahead frames, encoder scratch and a fixed process allowance.
    static func estimatedWorkerBytes(width: Int, height: Int, bitDepth: Int) -> UInt64 {
        let pixels = Double(max(1, width)) * Double(max(1, height))
        let estimate = 512 * 1024 * 1024 + pixels * (bitDepth > 8 ? 3 : 1.5) * 128
        return UInt64(min(estimate, Double(UInt64.max / 2)))
    }

    func workerLimit(width: Int, height: Int, bitDepth: Int, planned: Int, running: Int) -> Int {
        guard pressure != .critical else { return 0 }
        let estimate = Self.estimatedWorkerBytes(width: width, height: height, bitDepth: bitDepth)
        let physicalBudget = physicalBytes / 5 * 3
        let reserve = max(1024 * 1024 * 1024, physicalBytes / 8)
        let headroom = availableBytes > reserve ? availableBytes - reserve : 0
        let additional = Int(min(UInt64(Int.max), headroom / estimate))
        let physicalLimit = max(1, Int(min(UInt64(Int.max), physicalBudget / estimate)))
        // Always allow one worker outside critical pressure: a large encode can still
        // make progress on smaller Macs. Existing workers finish rather than being killed.
        let limit = min(max(1, planned), physicalLimit, max(1, running + additional))
        return pressure == .warning ? min(1, limit) : limit
    }
}

final class AV2MemoryMonitor: @unchecked Sendable {
    static let shared = AV2MemoryMonitor()
    private let state = OSAllocatedUnfairLock<AV2MemorySnapshot.Pressure>(initialState: .normal)
    private let source: DispatchSourceMemoryPressure

    private init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.source.data
            let pressure: AV2MemorySnapshot.Pressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            self.state.withLock { $0 = pressure }
        }
        source.resume()
    }

    func snapshot() -> AV2MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let physical = ProcessInfo.processInfo.physicalMemory
        // Inactive pages can be reclaimed. Wired, active and compressed pages are
        // deliberately excluded; pressure notifications provide an additional brake.
        let available = status == KERN_SUCCESS
            ? (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * UInt64(pageSize)
            : physical / 2
        return AV2MemorySnapshot(physicalBytes: physical, availableBytes: available, pressure: state.withLock { $0 })
    }
}
