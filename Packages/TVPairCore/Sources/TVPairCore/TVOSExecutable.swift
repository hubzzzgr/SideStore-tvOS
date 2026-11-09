import Foundation

/// Validate actual load commands, since an IPA's plist alone can claim tvOS.
public enum TVOSExecutable {
    public static func validate(url: URL) throws { try validate(Data(contentsOf: url, options: .mappedIfSafe)) }
    public static func validate(_ data: Data) throws {
        func number(_ offset: Int, _ count: Int = 4, big: Bool = false) throws -> UInt64 {
            guard offset >= 0, count <= data.count, offset <= data.count - count else { throw TVInstallationError.protocolFailure("Mach-O bounds") }
            let bytes = data.subdata(in: offset..<(offset + count))
            if big { return bytes.reduce(0) { ($0 << 8) | UInt64($1) } }
            return bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        var slices: [(Int, Int)] = []
        let magic = try number(0, big: true)
        if magic == 0xcafebabe || magic == 0xcafebabf {
            let count = try number(4), stride = magic == 0xcafebabf ? 32 : 20
            guard (1...32).contains(count) else { throw TVInstallationError.protocolFailure("fat Mach-O slice count") }
            for index in 0..<Int(count) {
                let item = 8 + index * stride
                let cpu = try number(item, big: true)
                let offset = try number(item + 8, magic == 0xcafebabf ? 8 : 4, big: true)
                let length = try number(item + (magic == 0xcafebabf ? 16 : 12), magic == 0xcafebabf ? 8 : 4, big: true)
                guard offset <= UInt64(data.count), length <= UInt64(data.count) - offset else { throw TVInstallationError.protocolFailure("fat Mach-O slice bounds") }
                if cpu == 0x0100000c { slices.append((Int(offset), Int(length))) }
            }
        } else { slices = [(0, data.count)] }
        guard !slices.isEmpty else { throw TVInstallationError.deviceRejected("IPA has no arm64 executable") }
        for (base, length) in slices {
            guard length >= 32, try number(base) == 0xfeedfacf, try number(base + 4) == 0x0100000c,
                  try number(base + 12) == 2 else { throw TVInstallationError.deviceRejected("IPA must contain an arm64 device executable") }
            let count = try number(base + 16), commandBytes = try number(base + 20)
            guard count > 0, count <= 4096, commandBytes <= UInt64(length - 32) else { throw TVInstallationError.protocolFailure("Mach-O command bounds") }
            let end = base + 32 + Int(commandBytes)
            var position = base + 32, tvOS = false
            for _ in 0..<count {
                guard position <= end - 8 else { throw TVInstallationError.protocolFailure("Mach-O command header") }
                let command = try number(position), size = try number(position + 4)
                guard size >= 8, size <= UInt64(end - position) else { throw TVInstallationError.protocolFailure("Mach-O command size") }
                if command == 0x32 { // LC_BUILD_VERSION: tvOS device=3, simulator=8
                    guard size >= 24, try number(position + 8) == 3 else { throw TVInstallationError.deviceRejected("Executable is not built for physical Apple TV") }
                    tvOS = true
                } else if command == 0x2f { // Legacy LC_VERSION_MIN_TVOS
                    guard size >= 16 else { throw TVInstallationError.protocolFailure("tvOS minimum version command") }
                    tvOS = true
                } else if command == 0x21 || command == 0x2c {
                    guard size >= 20, try number(position + 16) == 0 else { throw TVInstallationError.deviceRejected("Encrypted App Store executables cannot be re-signed") }
                }
                position += Int(size)
            }
            guard tvOS, position == end else { throw TVInstallationError.deviceRejected("Executable lacks valid tvOS platform load commands") }
        }
    }
}
