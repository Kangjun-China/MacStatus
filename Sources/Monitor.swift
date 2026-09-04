//
//  Monitor.swift
//  MacStatus
//
//  监控数据模型：定时采样 CPU 温度 / 风扇 / 内存 / CPU 占用 / 内存占用 Top App。
//

import Foundation
import SwiftUI

struct TempReading: Identifiable {
    let id: String  // SMC 键名
    let name: String
    let value: Double
    let category: String  // CPU / GPU / 供电 / 电池 / 环境
}

struct FanReading: Identifiable {
    let id: Int
    let rpm: Double
}

struct AppMemory: Identifiable {
    let id: String
    let name: String
    let bytes: UInt64
}

@MainActor
final class Monitor: ObservableObject {
    @Published var cpuTemp: Double?
    @Published var cpuUsage: Double = 0
    @Published var memUsed: UInt64 = 0
    @Published var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published var fans: [FanReading] = []
    @Published var topTemps: [TempReading] = []
    @Published var topApps: [AppMemory] = []
    @Published var fanCount: Int = 0
    @Published var smcOK = true
    @Published var lastUpdate = Date()

    /// 采样间隔（秒）
    let interval: TimeInterval = 2.0

    private var tempKeys: [String] = []
    private var timer: Timer?
    private var tick = 0

    init() {
        refresh()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        tick += 1
        do {
            try SMCKit.shared.open()
            smcOK = true
            if tempKeys.isEmpty {
                scanTempKeys()
            }
            sampleTemps()
            sampleFans()
        } catch {
            smcOK = false
        }

        let usage = SystemStats.cpuUsagePercent()
        if usage >= 0 {
            cpuUsage = usage
        }

        let mem = SystemStats.memoryInfo()
        memUsed = mem.used
        memTotal = mem.total

        // 内存 Top App 每 3 个周期采一次（约 6 秒），避免频繁 fork ps
        if tick % 3 == 1 {
            sampleAppMemory()
        }

        lastUpdate = Date()
    }

    /// 传感器分类：按 Apple Silicon 常见键名前缀归类
    static func sensorCategory(_ key: String) -> String {
        if key.hasPrefix("Tp") || key.hasPrefix("Tf") || key.hasPrefix("Te") || key.hasPrefix("TC") { return "CPU" }
        if key.hasPrefix("Tg") { return "GPU" }
        if key.hasPrefix("TV") { return "供电" }
        if key.hasPrefix("TB") { return "电池" }
        if key.hasPrefix("TA") { return "环境" }
        return ""
    }

    /// 枚举 SMC 中所有温度键（T 开头，sp78 / flt 类型）
    private func scanTempKeys() {
        guard let keys = try? SMCKit.shared.allKeys() else { return }
        var candidates: [String] = []
        for key in keys {
            guard key.hasPrefix("T") else { continue }
            guard let info = try? SMCKit.shared.keyInfo(key) else { continue }
            let type = stringFromFourCC(info.dataType)
            if type == "sp78" || type == "flt " {
                candidates.append(key)
            }
        }
        tempKeys = candidates
    }

    private func sampleTemps() {
        var readings: [TempReading] = []
        for key in tempKeys {
            guard let raw = try? SMCKit.shared.readRaw(key),
                  let value = SMCValueDecoder.decode(type: raw.type, bytes: raw.bytes),
                  value > 0, value < 130 else { continue }
            readings.append(TempReading(id: key,
                                        name: key,
                                        value: value,
                                        category: Self.sensorCategory(key)))
        }
        readings.sort { $0.value > $1.value }
        topTemps = Array(readings.prefix(4))

        // CPU 温度优先取 Tp*（Apple Silicon 性能核心传感器），否则取最高温度
        let cpuReadings = readings.filter { $0.name.hasPrefix("Tp") }
        if let maxCpu = cpuReadings.map(\.value).max() {
            cpuTemp = maxCpu
        } else {
            cpuTemp = readings.first?.value
        }
    }

    private func sampleFans() {
        guard let numRaw = try? SMCKit.shared.readRaw("FNum"),
              let count = SMCValueDecoder.decode(type: numRaw.type, bytes: numRaw.bytes),
              count > 0, count < 12 else {
            fanCount = 0
            fans = []
            return
        }
        fanCount = Int(count)
        // 注意：不要过滤 0 RPM —— M 系列空闲时风扇停转是正常状态
        var result: [FanReading] = []
        for i in 0..<Int(count) {
            if let value = try? SMCKit.shared.readValue("F\(i)Ac"), value >= 0 {
                result.append(FanReading(id: i, rpm: value))
            }
        }
        fans = result
    }

    // MARK: - 内存占用 Top5 App（libproc，按应用聚合 RSS）

    private func sampleAppMemory() {
        let total = Int(proc_listallpids(nil, 0))
        guard total > 0 else { return }
        var pids = [pid_t](repeating: 0, count: total)
        let n = proc_listallpids(&pids, Int32(total * MemoryLayout<pid_t>.stride))
        guard n > 0 else { return }

        var byApp: [String: UInt64] = [:]
        for index in 0..<Int(n) {
            let pid = pids[index]
            guard pid > 0 else { continue }

            // 完整可执行路径 → 应用名；拿不到路径时退回进程名
            var pathBuf = [CChar](repeating: 0, count: 4096)
            let name: String
            if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 {
                name = Self.appName(fromComm: String(cString: pathBuf))
            } else {
                var commBuf = [CChar](repeating: 0, count: 128)
                proc_name(pid, &commBuf, UInt32(commBuf.count))
                let comm = String(cString: commBuf)
                name = comm.isEmpty ? "pid \(pid)" : comm
            }

            var ri = rusage_info_current()
            let result: Int32 = withUnsafeMutableBytes(of: &ri) { buffer -> Int32 in
                // 正确语义：内核把 rusage 结构直接写进 buffer 指向的内存，
                // 必须传 ri 自身的地址（C 等价于 (rusage_info_t *)&ri）。
                // 错误写法（传 &ptr）会用整个结构覆盖栈上的指针变量，踩内存。
                let p = buffer.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self)
                return proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, p)
            }
            guard result == 0 else { continue }
            // phys_footprint 与活动监视器"内存"列口径一致，避免共享页重复计数
            byApp[name, default: 0] += ri.ri_phys_footprint
        }

        topApps = byApp
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { AppMemory(id: $0.key, name: $0.key, bytes: $0.value) }
    }

    /// 从可执行文件路径提取应用名，Helper 进程聚合到主 App
    /// 例：/Applications/WeChat.app/Contents/Frameworks/X.app/... → WeChat
    static func appName(fromComm comm: String) -> String {
        if let range = comm.range(of: ".app/") {
            let before = comm[..<range.lowerBound]  // ".../WeChat"
            let name = before.split(separator: "/").last ?? before
            return String(name)
        }
        return (comm as NSString).lastPathComponent
    }
}
