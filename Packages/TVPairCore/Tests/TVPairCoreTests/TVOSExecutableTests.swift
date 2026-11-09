import XCTest
@testable import TVPairCore

final class TVOSExecutableTests: XCTestCase {
    private func executable(platform: UInt64 = 3, encrypted: Bool = false) -> Data {
        var words: [UInt64] = [0xfeedfacf, 0x0100000c, 0, 2, encrypted ? 2 : 1, encrypted ? 48 : 24, 0, 0]
        words += [0x32, 24, platform, 0, 0, 0]
        if encrypted { words += [0x2c, 24, 0, 0, 1, 0] }
        var data = Data()
        for word in words { data.append(XPCCodec.le(word)) }
        return data
    }
    func testAcceptsDeviceTVOSExecutable() throws { try TVOSExecutable.validate(executable()) }
    func testRejectsSimulatorEvenWithArm64CPU() { XCTAssertThrowsError(try TVOSExecutable.validate(executable(platform: 8))) }
    func testRejectsIPhoneExecutable() { XCTAssertThrowsError(try TVOSExecutable.validate(executable(platform: 2))) }
    func testRejectsEncryptedExecutable() { XCTAssertThrowsError(try TVOSExecutable.validate(executable(encrypted: true))) }
    func testRejectsTruncatedCommands() { XCTAssertThrowsError(try TVOSExecutable.validate(Data(executable().dropLast()))) }
    func testRejectsUnboundedFatHeader() { XCTAssertThrowsError(try TVOSExecutable.validate(Data([0xca, 0xfe, 0xba, 0xbe, 0xff, 0xff, 0xff, 0xff]))) }
}
