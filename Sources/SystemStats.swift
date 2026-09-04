//
//  SystemStats.swift
//  MacStatus
//
//  CPU 使用率（Mach processor_load_info）与内存使用量（host_statistics64）。
//

import Foundation
import Darwin

enum SystemStats {
    // MARK: CPU 使用率

    private static var prevBusy: UInt64 = 0
    private static var prevTotal: UInt64 = 0

    /// 返回两次采样间的 CPU 使用率百分比（0-100），首次调用返回 -1
    static func cpuUsagePercent() -> Double {
        var processorCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(mach_host_self(),
                                     PROCESSOR_CPU_LOAD_INFO,
                                     &processorCount,
                                     &cpuInfo,
                                     &cpuInfoCount)
        guard kr == KERN_SUCCESS, let info = cpuInfo, processorCount > 0 else { return -1 }

        var busyTotal: UInt64 = 0
        var totalTotal: UInt64 = 0
        for cpu in 0..<Int(processorCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            let busy = user + system + nice
            busyTotal += busy
            totalTotal += busy + idle
        }

        let stateSize = vm_size_t(processorCount) *
            vm_size_t(MemoryLayout<processor_cpu_load_info_data_t>.size) /
            vm_size_t(MemoryLayout<integer_t>.size)
        _ = vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          stateSize)

        let dBusy = busyTotal > prevBusy ? busyTotal - prevBusy : 0
        let dTotal = totalTotal > prevTotal ? totalTotal - prevTotal : 0
        prevBusy = busyTotal
        prevTotal = totalTotal

        guard dTotal > 0 else { return -1 }
        return Double(dBusy) / Double(dTotal) * 100.0
    }

    // MARK: 内存

    struct MemoryInfo {
        let used: UInt64
        let total: UInt64
        var usedPercent: Double { total > 0 ? Double(used) / Double(total) * 100.0 : 0 }
    }

    /// 已用 = active + wired + compressed（与活动监视器口径接近）
    static func memoryInfo() -> MemoryInfo {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            return MemoryInfo(used: 0, total: ProcessInfo.processInfo.physicalMemory)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(bitPattern: Int64(stats.active_count))
        let wired = UInt64(bitPattern: Int64(stats.wire_count))
        let compressed = UInt64(bitPattern: Int64(stats.compressor_page_count))
        let used = (active + wired + compressed) * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        return MemoryInfo(used: min(used, total), total: total)
    }
}
