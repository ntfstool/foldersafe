import XCTest
@testable import FolderSafeCore

/// 仓库里公开的测试向量（docs/spec/test-vectors/v1.json）必须和本实现一致，且能逐字节重新生成。
final class VectorTests: XCTestCase {
    let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/spec/test-vectors/v1.json")

    func testPublishedVectorsVerify() throws {
        try TestVectors.verify(try Data(contentsOf: file))
    }

    func testPublishedVectorsAreReproducible() throws {
        XCTAssertEqual(try TestVectors.generate(), try Data(contentsOf: file),
                       "实现变了导致向量变化：先确认是否破坏了格式兼容，再用 fsvault vectors --out 重新生成")
    }
}
