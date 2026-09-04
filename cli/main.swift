//
//  cli/main.swift — SMC 读取验证工具（不参与 App 构建）
//

import Foundation

do {
    try SMCKit.shared.open()
    print("SMC 连接成功")

    let count = try SMCKit.shared.keyCount()
    print("键总数: \(count)")

    let keys = try SMCKit.shared.allKeys()
    print("枚举到 \(keys.count) 个键")

    // 风扇
    if let fanCount = try? SMCKit.shared.readValue("FNum") {
        print("风扇数量: \(fanCount)")
        for i in 0..<Int(fanCount) {
            if let rpm = try? SMCKit.shared.readValue("F\(i)Ac") {
                print("  F\(i)Ac = \(rpm) RPM")
            }
        }
    }

    // 温度键（T 开头 sp78/flt）
    var temps: [(String, Double)] = []
    for key in keys where key.hasPrefix("T") {
        guard let raw = try? SMCKit.shared.readRaw(key) else { continue }
        guard let v = SMCValueDecoder.decode(type: raw.type, bytes: raw.bytes),
              v > 0, v < 130 else { continue }
        temps.append((key, v))
    }
    temps.sort { $0.1 > $1.1 }
    print("有效温度键 \(temps.count) 个，前 12 个：")
    for (k, v) in temps.prefix(12) {
        print("  \(k) = \(String(format: "%.1f", v))°C")
    }

    let tp = temps.filter { $0.0.hasPrefix("Tp") }.map(\.1).max()
    print("CPU(Tp*) 最高温度: \(tp.map { String(format: "%.1f°C", $0) } ?? "无")")

    print(String(format: "CPU 使用率: %.1f%%", SystemStats.cpuUsagePercent()))
    Thread.sleep(forTimeInterval: 1)
    print(String(format: "CPU 使用率: %.1f%%", SystemStats.cpuUsagePercent()))

    let mem = SystemStats.memoryInfo()
    print(String(format: "内存: %.1f / %.1f GB (%.0f%%)",
                 Double(mem.used) / 1_073_741_824,
                 Double(mem.total) / 1_073_741_824,
                 mem.usedPercent))
} catch {
    print("错误: \(error)")
    exit(1)
}
