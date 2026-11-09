import XCTest
@testable import TVPairCore

final class TVOSExecutableTests: XCTestCase {
    private func executable(platform: UInt64 = 3, encrypted: Bool = false) -> Data {
        let u = { (x: UInt64) in XPCCodec.le(x) }
        var data = u(0xfeedfacf) + u(0x0100000c) + u(0) + u(2) + u(encrypted ? 2 : 1) + u(encrypted ? 48 : 24) + u(0) + u(0)
        data += u(0x32) + u(24) + u(platform) + u(0) + u(0) + u(0)
        if encrypted { data += u(0x2c) + u(24) + u(0) + u(0) + u(1) + u(0) }
        return data
    }
    func testAcceptsDeviceTVOSExecutable() throws { try TVOSExecutable.validate(executable()) }
    func testRejectsSimulatorEvenWithArm64CPU() { XCTAssertThrowsError(try TVOSExecutable.validate(executable(platform: 8))) }
    func testRejectsIPhoneExecutable() { XCTAssertThrowsError(try TVOSExecutable.validate(executable(platform: 2))) }
    func testRejectsEncryptedExecutable() { XCTAssertThrowsError(try TVOSExecutable.validate(executable(encrypted: true))) }
    func testRejectsTruncatedCommands() { XCTAssertThrowsError(try TVOSExecutable.validate(Data(executable().dropLast()))) }
    func testRejectsUnboundedFatHeader() { XCTAssertThrowsError(try TVOSExecutable.validate(Data([0xca, 0xfe, 0xba, 0xbe, 0xff, 0xff, 0xff, 0xff]))) }
}
