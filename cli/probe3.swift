//
//  cli/probe3.swift — 新版 SMC 接口探针：selector 2 + data8 命令字节（不参与 App 构建）
//

import Foundation
import IOKit

@main
struct SMCProbe3 {
    static func main() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { print("no AppleSMC"); exit(1) }
        defer { IOObjectRelease(service) }

        for openType in UInt32(0)...1 {
            var conn: io_connect_t = 0
            let openKr = IOServiceOpen(service, mach_task_self_, openType, &conn)
            guard openKr == KERN_SUCCESS else {
                print("type=\(openType): open kr=\(openKr)")
                continue
            }
            defer { IOServiceClose(conn) }

            for cmd in UInt8(0)...10 {
                var input = SMCParamStruct()
                var output = SMCParamStruct()
                input.key = 0x234B4559 // "#KEY"
                input.keyInfo.dataSize = 4
                input.data8 = cmd
                var outSize = MemoryLayout<SMCParamStruct>.size
                let kr = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParamStruct>.size, &output, &outSize)
                let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(8)).map { String(format: "%02x", $0) } }.joined()
                print("type=\(openType) sel=2 cmd=\(cmd): kr=\(kr) result=\(output.result) dataSize=\(output.keyInfo.dataSize) bytes=\(bytes)")
            }
        }
    }
}
