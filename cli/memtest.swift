//
//  cli/memtest.swift — 验证 proc_pid_rusage 数值与单位（不参与 App 构建）
//

import Foundation
import Darwin

@main
struct MemTest {
    static func main() {
        let total = Int(proc_listallpids(nil, 0))
        guard total > 0 else { return }
        var pids = [pid_t](repeating: 0, count: total)
        let n = proc_listallpids(&pids, Int32(total * MemoryLayout<pid_t>.stride))
        print("进程数: \(n)")

        struct Row {
            let name: String
            let resident: UInt64
            let footprint: UInt64
        }
        var rows: [Row] = []

        for index in 0..<Int(n) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var pathBuf = [CChar](repeating: 0, count: 4096)
            let name: String
            if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 {
                name = String(cString: pathBuf)
            } else {
                name = "?"
            }

            var ri = rusage_info_current()
            let result: Int32 = withUnsafeMutableBytes(of: &ri) { buffer -> Int32 in
                // 正确语义：内核把 rusage 结构直接写进 buffer 指向的内存，
                // 因此必须传 ri 自身的地址（C 里等价于 (rusage_info_t *)&ri）
                let p = buffer.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self)
                return proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, p)
            }
            guard result == 0 else { continue }
            rows.append(Row(name: name, resident: ri.ri_resident_size, footprint: ri.ri_phys_footprint))
        }

        print("---- resident_size 字节 Top8 ----")
        for row in rows.sorted(by: { $0.resident > $1.resident }).prefix(8) {
            print(String(format: "%12llu B = %8.1f MB  fp=%8.1f MB  %@",
                         row.resident,
                         Double(row.resident) / 1048576,
                         Double(row.footprint) / 1048576,
                         row.name))
        }
        print("---- phys_footprint Top8 ----")
        for row in rows.sorted(by: { $0.footprint > $1.footprint }).prefix(8) {
            print(String(format: "fp=%12llu B = %8.1f MB  rs=%8.1f MB  %@",
                         row.footprint,
                         Double(row.footprint) / 1048576,
                         Double(row.resident) / 1048576,
                         row.name))
        }

        // 验证 rusage 结构布局：打印 ri_resident_size 字段偏移与原始内存
        var ri = rusage_info_current()
        let zeroed = withUnsafeBytes(of: &ri) { $0.allSatisfy { $0 == 0 } }
        print("rusage_info_current 默认全零: \(zeroed) size=\(MemoryLayout<rusage_info_current>.size)")
    }
}
