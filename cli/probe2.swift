//
//  cli/probe2.swift — 探测不同服务名与 open type 下的键读取（不参与 App 构建）
//

import Foundation
import IOKit

@main
struct SMCProbe2 {
    static func main() {
        let names = ["AppleSMC", "AppleSMCEmbedded", "SMCHelper", "AppleSMCClient", "IOService:/AppleSMC"]
        for name in names {
            var iterator: io_iterator_t = 0
            let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator)
            guard kr == KERN_SUCCESS else {
                print("\(name): match kr=\(kr)")
                continue
            }
            var count = 0
            defer { IOObjectRelease(iterator) }
            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 { break }
                count += 1
                var nameBuf = [CChar](repeating: 0, count: 128)
                IORegistryEntryGetName(service, &nameBuf)
                let regName = String(cString: nameBuf)
                for type in UInt32(0)...2 {
                    var conn: io_connect_t = 0
                    let openKr = IOServiceOpen(service, mach_task_self_, type, &conn)
                    guard openKr == KERN_SUCCESS else {
                        print("\(regName) type=\(type): open kr=\(openKr)")
                        continue
                    }
                    // 试 selector 9 (GetKeyInfo "#KEY")
                    var input = SMCParamStruct()
                    var output = SMCParamStruct()
                    input.key = 0x234B4559 // "#KEY" big-endian
                    input.keyInfo.dataSize = 4
                    var outSize = MemoryLayout<SMCParamStruct>.size
                    let callKr = IOConnectCallStructMethod(conn, 9, &input, MemoryLayout<SMCParamStruct>.size, &output, &outSize)
                    let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(8)).map { String(format: "%02x", $0) } }.joined()
                    print("\(regName) type=\(type): open=0 call9 kr=\(callKr) result=\(output.result) dataSize=\(output.keyInfo.dataSize) bytes=\(bytes)")
                    IOServiceClose(conn)
                }
                IOObjectRelease(service)
            }
            print("\(name): \(count) 个服务")
        }
    }
}
