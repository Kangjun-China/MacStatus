//
//  SMCKit.swift
//  MacStatus
//
//  通过 IOKit 用户客户端直接读取 AppleSMC，无需 root 权限。
//  结构体内存布局必须与 C 版 SMCParamStruct 严格一致（共 80 字节）。
//

import Foundation
import IOKit

// MARK: - 与内核对齐的 SMC 参数结构

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    /// 显式尾部对齐填充：Swift 不自动补齐到 4 字节对齐，C 版此结构为 12 字节
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

let smcZeroBytes: SMCBytes = (
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0
)

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = smcZeroBytes
}

// MARK: - fourCC 工具

/// "F0Ac" -> big-endian UInt32（与 Apple SMC 键名编码一致）
func fourCC(_ s: String) -> UInt32 {
    var r: UInt32 = 0
    for b in s.utf8.prefix(4) {
        r = (r << 8) | UInt32(b)
    }
    return r
}

func stringFromFourCC(_ v: UInt32) -> String {
    let chars = [
        UInt8((v >> 24) & 0xff),
        UInt8((v >> 16) & 0xff),
        UInt8((v >> 8) & 0xff),
        UInt8(v & 0xff),
    ].filter { $0 != 0 }
    return String(bytes: chars, encoding: .utf8) ?? ""
}

// MARK: - 字节组转换

func tupleBytes(_ t: SMCBytes) -> [UInt8] {
    var t = t
    return withUnsafeBytes(of: &t) { Array($0) }
}

// MARK: - SMC 键值解码

enum SMCValueDecoder {
    /// 按 SMC 数据类型把原始字节解码为 Double
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        guard bytes.count >= 2 else {
            if type == "ui8 " && !bytes.isEmpty { return Double(bytes[0]) }
            if type == "ui8 " { return nil }
            return nil
        }
        func u16be(_ i: Int) -> UInt16 { (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1]) }
        func i16be(_ i: Int) -> Int16 { Int16(bitPattern: u16be(i)) }

        switch type {
        case "sp78": // 温度：8.8 有符号定点
            return Double(i16be(0)) / 256.0
        case "fpe2": // 风扇转速：定点 /4
            return Double(i16be(0)) / 4.0
        case "fp1e":
            return Double(i16be(0)) / 16.0
        case "fp4c":
            return Double(i16be(0)) / 65536.0
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: bits))
        case "ui8 ":
            return Double(bytes[0])
        case "ui16":
            return Double(u16be(0))
        default:
            return nil
        }
    }
}

// MARK: - SMCKit

final class SMCKit {
    enum SMCError: Error, LocalizedError {
        case serviceNotFound
        case openFailed(kr: kern_return_t)
        case ioFailed(kr: kern_return_t)
        case keyError(result: UInt8)

        var errorDescription: String? {
            switch self {
            case .serviceNotFound:
                return "找不到 AppleSMC 服务"
            case .openFailed(let kr):
                return "SMC 连接打开失败: kr=\(kr)"
            case .ioFailed(let kr):
                return "SMC IO 调用失败: kr=\(kr)"
            case .keyError(let result):
                return "SMC 键错误: result=\(result)"
            }
        }
    }

    // macOS 26+ 新版 AppleSMC 接口：所有命令统一走用户客户端选择器 2，
    // 命令字节放在 input.data8（旧版的选择器 5/8/9 已被移除，会返回 Unsupported）。
    private enum Command {
        static let readKey: UInt8 = 5
        static let writeKey: UInt8 = 6
        static let getKeyFromIndex: UInt8 = 8
        static let getKeyInfo: UInt8 = 9
    }

    private let callSelector: UInt32 = 2

    /// macOS 26 及以前可能仍是旧协议（命令字节直接当选择器用），启动时自动探测
    private var usesLegacySelectors = false

    static let shared = SMCKit()

    private var conn: io_connect_t = 0
    private var isOpen = false

    func open() throws {
        guard !isOpen else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed(kr: kr) }
        isOpen = true
        detectProtocol()
    }

    /// 探测 SMC 协议版本：先用新版（选择器 2 + data8），失败则回退旧选择器
    private func detectProtocol() {
        var input = SMCParamStruct()
        input.key = fourCC("#KEY")
        input.keyInfo.dataSize = 4
        var output = SMCParamStruct()
        do {
            try call(Command.getKeyInfo, input: &input, output: &output)
        } catch {
            usesLegacySelectors = true
        }
    }

    func close() {
        guard isOpen else { return }
        _ = IOServiceClose(conn)
        conn = 0
        isOpen = false
    }

    private func call(_ command: UInt8,
                      input: inout SMCParamStruct,
                      output: inout SMCParamStruct) throws {
        assert(MemoryLayout<SMCParamStruct>.size == 80,
               "SMCParamStruct 布局异常: \(MemoryLayout<SMCParamStruct>.size)")
        if usesLegacySelectors {
            // 旧协议：命令字节直接作为用户客户端选择器
            input.data8 = 0
        } else {
            // 新协议（macOS 26/27+）：统一选择器 2，命令放 data8
            input.data8 = command
        }
        var outSize = MemoryLayout<SMCParamStruct>.size
        let kr = IOConnectCallStructMethod(conn,
                                           usesLegacySelectors ? UInt32(command) : callSelector,
                                           &input,
                                           MemoryLayout<SMCParamStruct>.size,
                                           &output,
                                           &outSize)
        guard kr == KERN_SUCCESS else { throw SMCError.ioFailed(kr: kr) }
    }

    /// 查询键元信息（长度 / 类型）
    func keyInfo(_ key: UInt32) throws -> SMCKeyInfoData {
        var input = SMCParamStruct()
        input.key = key
        var output = SMCParamStruct()
        try call(Command.getKeyInfo, input: &input, output: &output)
        guard output.result == 0 else { throw SMCError.keyError(result: output.result) }
        return output.keyInfo
    }

    func keyInfo(_ name: String) throws -> SMCKeyInfoData {
        try keyInfo(fourCC(name))
    }

    /// 读取键原始数据
    func readRaw(_ key: UInt32) throws -> (type: String, size: Int, bytes: [UInt8]) {
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo = info
        var output = SMCParamStruct()
        try call(Command.readKey, input: &input, output: &output)
        guard output.result == 0 else { throw SMCError.keyError(result: output.result) }
        let size = Int(info.dataSize)
        return (stringFromFourCC(info.dataType), size, Array(tupleBytes(output.bytes).prefix(size)))
    }

    func readRaw(_ name: String) throws -> (type: String, size: Int, bytes: [UInt8]) {
        try readRaw(fourCC(name))
    }

    /// 读取并解码为数值
    func readValue(_ name: String) throws -> Double? {
        let raw = try readRaw(name)
        return SMCValueDecoder.decode(type: raw.type, bytes: raw.bytes)
    }

    /// SMC 键总数（#KEY）
    func keyCount() throws -> UInt32 {
        let raw = try readRaw("#KEY")
        guard raw.bytes.count >= 4 else { throw SMCError.keyError(result: 0xff) }
        let b = raw.bytes
        let be = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        let le = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
        return be < 65536 ? be : le
    }

    /// 枚举全部 SMC 键名
    func allKeys() throws -> [String] {
        let count = try keyCount()
        guard count < 100_000 else { throw SMCError.keyError(result: 0xfe) }
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        for index in 0..<count {
            var input = SMCParamStruct()
            input.data8 = UInt8(truncatingIfNeeded: index)
            input.data32 = index
            var output = SMCParamStruct()
            do {
                try call(Command.getKeyFromIndex, input: &input, output: &output)
            } catch {
                continue
            }
            guard output.result == 0 else { continue }
            let name = stringFromFourCC(output.key)
            if name.count == 4 {
                keys.append(name)
            }
        }
        return keys
    }
}
