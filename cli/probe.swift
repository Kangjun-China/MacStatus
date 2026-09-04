//
//  cli/probe.swift — SMC 选择器探针（不参与 App 构建）
//

import Foundation
import IOKit

@main
struct SMCProbe {
    static func main() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { print("no AppleSMC"); exit(1) }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let openKr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        print("open kr=\(openKr) conn=\(conn)")
        guard openKr == KERN_SUCCESS else { exit(1) }
        defer { _ = IOServiceClose(conn) }

        // GetKeyInfo 探针：键 "#KEY"
        print("---- 探针 (#KEY) ----")
        for sel in 0...16 {
            var input = SMCParamStruct()
            var output = SMCParamStruct()
            input.key = fourCC("#KEY")
            input.keyInfo.dataSize = 4
            var outSize = MemoryLayout<SMCParamStruct>.size
            let kr = IOConnectCallStructMethod(conn, UInt32(sel), &input, MemoryLayout<SMCParamStruct>.size, &output, &outSize)
            let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(8)).map { String(format: "%02x", $0) } }.joined()
            let typeBytes: [UInt8] = [
                UInt8((output.keyInfo.dataType >> 24) & 0xff),
                UInt8((output.keyInfo.dataType >> 16) & 0xff),
                UInt8((output.keyInfo.dataType >> 8) & 0xff),
                UInt8(output.keyInfo.dataType & 0xff),
            ]
            let typeStr = String(bytes: typeBytes.filter { $0 != 0 }, encoding: .ascii) ?? "?"
            print("selector=\(sel): kr=\(kr) result=\(output.result) dataSize=\(output.keyInfo.dataSize) type=\(typeStr) key=\(String(format: "%08x", output.key)) bytes=\(bytes)")
        }
    }
}
