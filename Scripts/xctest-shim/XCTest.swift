// A minimal stand-in for XCTest, for machines that have Command Line Tools but
// no Xcode (XCTest.framework ships inside Xcode's Platforms directory, not in
// the SDK). Compiled with -module-name XCTest, so the test files' plain
// `import XCTest` resolves here and they need no changes at all. When a full
// toolchain is present, `swift test` uses the real XCTest and this is unused.
//
// Only the assertions the test suite actually uses are implemented.
import Foundation

public final class TestFailureRecorder {
    public static let shared = TestFailureRecorder()
    public var failures: [String] = []
    public var currentTest: String = ""
    public func record(_ message: String, _ file: StaticString, _ line: UInt) {
        failures.append("\(currentTest): \(message) (\(file):\(line))")
    }
}

open class XCTestCase {
    public init() {}
    open func setUp() {}
    open func tearDown() {}
}

public struct XCTestError: Error, CustomStringConvertible {
    public let description: String
}

private func fail(_ message: String, _ extra: String, _ file: StaticString, _ line: UInt) {
    let suffix = extra.isEmpty ? "" : " - \(extra)"
    TestFailureRecorder.shared.record(message + suffix, file, line)
}

public func XCTFail(_ message: String = "", file: StaticString = #file, line: UInt = #line) {
    fail("XCTFail", message, file, line)
}

public func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                          file: StaticString = #file, line: UInt = #line) {
    do { if try !expression() { fail("XCTAssertTrue failed", message(), file, line) } }
    catch { fail("threw \(error)", message(), file, line) }
}

public func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                           file: StaticString = #file, line: UInt = #line) {
    do { if try expression() { fail("XCTAssertFalse failed", message(), file, line) } }
    catch { fail("threw \(error)", message(), file, line) }
}

public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                         _ message: @autoclosure () -> String = "",
                                         file: StaticString = #file, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        if x != y { fail("XCTAssertEqual failed: (\"\(x)\") is not equal to (\"\(y)\")", message(), file, line) }
    } catch { fail("threw \(error)", message(), file, line) }
}

public func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                             accuracy: T, _ message: @autoclosure () -> String = "",
                                             file: StaticString = #file, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        if !(abs(x - y) <= accuracy) {
            fail("XCTAssertEqual failed: (\"\(x)\") is not equal to (\"\(y)\") +/- \(accuracy)", message(), file, line)
        }
    } catch { fail("threw \(error)", message(), file, line) }
}

public func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                            _ message: @autoclosure () -> String = "",
                                            file: StaticString = #file, line: UInt = #line) {
    do { if try a() == b() { fail("XCTAssertNotEqual failed", message(), file, line) } }
    catch { fail("threw \(error)", message(), file, line) }
}

public func XCTAssertNil(_ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "",
                         file: StaticString = #file, line: UInt = #line) {
    do { if let value = try expression() { fail("XCTAssertNil failed: got \(value)", message(), file, line) } }
    catch { fail("threw \(error)", message(), file, line) }
}

public func XCTAssertNotNil(_ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "",
                            file: StaticString = #file, line: UInt = #line) {
    do { if try expression() == nil { fail("XCTAssertNotNil failed", message(), file, line) } }
    catch { fail("threw \(error)", message(), file, line) }
}

public func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "",
                         file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value = try expression() else {
        fail("XCTUnwrap failed: value was nil", message(), file, line)
        throw XCTestError(description: "XCTUnwrap found nil")
    }
    return value
}

public func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                                _ message: @autoclosure () -> String = "",
                                                file: StaticString = #file, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        if !(x > y) { fail("XCTAssertGreaterThan failed: (\"\(x)\") is not greater than (\"\(y)\")", message(), file, line) }
    } catch { fail("threw \(error)", message(), file, line) }
}

public func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                                       _ message: @autoclosure () -> String = "",
                                                       file: StaticString = #file, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        if !(x >= y) { fail("XCTAssertGreaterThanOrEqual failed: (\"\(x)\") < (\"\(y)\")", message(), file, line) }
    } catch { fail("threw \(error)", message(), file, line) }
}

public func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                             _ message: @autoclosure () -> String = "",
                                             file: StaticString = #file, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        if !(x < y) { fail("XCTAssertLessThan failed: (\"\(x)\") is not less than (\"\(y)\")", message(), file, line) }
    } catch { fail("threw \(error)", message(), file, line) }
}

public func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                                    _ message: @autoclosure () -> String = "",
                                                    file: StaticString = #file, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        if !(x <= y) { fail("XCTAssertLessThanOrEqual failed: (\"\(x)\") > (\"\(y)\")", message(), file, line) }
    } catch { fail("threw \(error)", message(), file, line) }
}

public func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
                                    file: StaticString = #file, line: UInt = #line,
                                    _ errorHandler: (Error) -> Void = { _ in }) {
    do { _ = try expression(); fail("XCTAssertThrowsError failed: no error thrown", message(), file, line) }
    catch { errorHandler(error) }
}

public func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
                                file: StaticString = #file, line: UInt = #line) {
    do { _ = try expression() } catch { fail("XCTAssertNoThrow failed: threw \(error)", message(), file, line) }
}
