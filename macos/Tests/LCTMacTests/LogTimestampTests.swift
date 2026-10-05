import XCTest
@testable import LCTMac

/// Guards the appLog timestamp prefix format: every log line starts with
/// "HH:mm:ss.SSS" in local time.
final class LogTimestampTests: XCTestCase {

    func testLogTimestamp_Format_MatchesHourMinuteSecondMillis() {
        let stamp = LogTimestamp.makeFormatter().string(from: Date())
        let pattern = #"^\d{2}:\d{2}:\d{2}\.\d{3}$"#
        XCTAssertNotNil(stamp.range(of: pattern, options: .regularExpression),
                        "timestamp must match HH:mm:ss.SSS, got '\(stamp)'")
    }

    func testLogTimestamp_KnownDate_RendersLocalComponents() {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 2
        components.hour = 7
        components.minute = 8
        components.second = 9
        components.nanosecond = 250_000_000
        guard let date = Calendar.current.date(from: components) else {
            XCTFail("could not build reference date")
            return
        }
        XCTAssertEqual(LogTimestamp.makeFormatter().string(from: date), "07:08:09.250")
    }
}
