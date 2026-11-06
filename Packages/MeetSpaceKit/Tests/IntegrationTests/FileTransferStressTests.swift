import Foundation
import CryptoKit
import Testing
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage

/// Real import/staging and repository upload contract; transport validates the on-disk input.
/// This deliberately does not measure HTTPS throughput or pretend to upload to a real backend.
@Test func stage08ThirtyMaximumSizeUploadStagingCyclesCleanAccountFiles() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("stage08-files-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("payload.zip")
    let bytes = Data(repeating: 0x37, count: FilePolicy.maximumBytes)
    try bytes.write(to: source)
    let hash = SHA256.hash(data: bytes)
    let store = AccountFileStore(account: try Fixture.account(), baseDirectory: base.appendingPathComponent("cache"))
    let attachmentID = UUID(), conversation = Fixture.conversationID.uuidString.lowercased()
    let path = "/api/v1/conversations/\(conversation)/attachments/\(attachmentID.uuidString.lowercased())/content"
    let transport = RoutedTransport { request, file in
        var attachment: [String: Any] = ["id": attachmentID.uuidString, "conversationId": conversation,
            "ownerId": Fixture.userID.uuidString, "filename": "payload.zip", "mimeType": "application/zip",
            "size": FilePolicy.maximumBytes, "status": "pending", "expiresAt": "2099-01-01T00:00:00Z"]
        if request.url!.path.hasSuffix("/init") { return try Fixture.response(["item": attachment, "uploadUrl": "https://fixture.example" + path]) }
        if request.httpMethod == "PUT" {
            #expect(request.httpBody == nil)
            let file = try #require(file)
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            var digest = SHA256(), count = 0
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty { digest.update(data: chunk); count += chunk.count }
            #expect(count == FilePolicy.maximumBytes && digest.finalize() == hash)
            return NetworkResponse(status: 204)
        }
        attachment["status"] = "ready"
        return try Fixture.response(["item": attachment])
    }
    let client = AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
    let repo = MessagingRepository(client: client)
    for _ in 0..<30 {
        let staged = try await store.stage(source)
        let input = UploadInput(id: staged.id, filename: staged.filename, mimeType: staged.mimeType, size: staged.size)
        let attachment = try await repo.upload(Fixture.conversationID, input: input, file: staged.url)
        #expect(attachment.status == "ready" && attachment.size == FilePolicy.maximumBytes)
        await store.remove(staged.url)
        #expect(!FileManager.default.fileExists(atPath: staged.url.path))
    }
    #expect(await transport.requests.count == 90)
    try await store.clear(); _ = try await client.close()
    #expect(try Data(contentsOf: source) == bytes)
}
