import Foundation
import Testing
@testable import MemoirProcessorCore

struct HTTPRequestDecoderTests {
    @Test(arguments: ["-1", "9223372036854775808", "1073741825", "nope", "+1"])
    func malformedLengthIsRejected(length: String) {
        let decoder = HTTPRequestDecoder()
        #expect(throws: ProcessorError.self) {
            _ = try decoder.append(Data("PUT /upload HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n".utf8))
        }
    }

    @Test func uploadIsSpooledAcrossArbitraryChunks() throws {
        let decoder = HTTPRequestDecoder()
        #expect(try decoder.append(Data("PUT /v1/sessions/test/files/system HTTP/1.1\r\nContent-Len".utf8)) == nil)
        #expect(try decoder.append(Data("gth: 6\r\n\r\nabc".utf8)) == nil)
        let result = try #require(try decoder.append(Data("def".utf8)))
        let url = try #require(result.uploadURL)
        #expect(result.body.isEmpty)
        #expect(try Data(contentsOf: url) == Data("abcdef".utf8))
    }

    @Test func authorizationRejectsBeforeReceivingBody() {
        let decoder = HTTPRequestDecoder { _, _, _ in throw ProcessorError(code: "unauthorized", message: "No", retryable: false) }
        #expect(throws: ProcessorError.self) {
            _ = try decoder.append(Data("PUT /upload HTTP/1.1\r\nContent-Length: 1000000\r\n\r\n".utf8))
        }
    }

    @Test func ambiguousFramingIsRejected() {
        for headers in ["Content-Length: 1\r\nContent-Length: 2", "Transfer-Encoding: chunked", "Content-Length: 0\r\nTransfer-Encoding: chunked"] {
            #expect(throws: ProcessorError.self) {
                _ = try HTTPRequestDecoder().append(Data("POST /v1/sessions HTTP/1.1\r\n\(headers)\r\n\r\n".utf8))
            }
        }
    }

    @Test func largeWorkerOutputDoesNotDeadlock() throws {
        let result = try SubprocessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import sys; sys.stdout.write('x'*200000); sys.stderr.write('y'*200000)"], timeout: 10)
        #expect(result.status == 0)
        #expect(result.output.count == 200000)
        #expect(result.error.count == 200000)
    }
}
