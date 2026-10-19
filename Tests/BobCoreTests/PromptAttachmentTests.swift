import AppKit
import XCTest
@testable import Bob
@testable import BobCore

final class PromptAttachmentTests: XCTestCase {
    private var image: ModelImage { .init(data: Data([1, 2, 3]), mimeType: "image/png", width: 20, height: 10) }

    func testUserImagesReachEveryAPIFormat() throws {
        let messages = [ModelMessage(role: "user", text: "Describe", images: [image])]
        let responses = try ModelClient.responsesInput(messages)
        let responseBlocks = try XCTUnwrap(responses.first?["content"] as? [[String: Any]])
        XCTAssertEqual(responseBlocks.last?["image_url"] as? String, image.dataURL)
        let chat = ModelClient.chatInput(messages)
        XCTAssertEqual(chat.count, 1, "User attachments belong on the original user message")
        let chatBlocks = try XCTUnwrap(chat.first?["content"] as? [[String: Any]])
        XCTAssertEqual((chatBlocks.last?["image_url"] as? [String: String])?["url"], image.dataURL)
        let anthropic = ModelClient.anthropicInput(messages)
        let blocks = try XCTUnwrap(anthropic.first?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.last?["type"] as? String, "image")
        XCTAssertEqual((blocks.last?["source"] as? [String: String])?["data"], image.data.base64EncodedString())
    }

    func testSteeringRetainsImagesAndMessageIdentity() {
        let input = AgentInput()
        let id = UUID()
        input.send("Look", id: id, images: [image])
        let pending = input.takePending()
        XCTAssertEqual(pending.first?.images, [image])
        XCTAssertEqual(pending.first?.userMessageID, id)
    }

    func testMessageAttachmentPersistenceAndLegacyDecoding() throws {
        let message = Message(role: .user, text: "Look", images: [image])
        let data = try JSONEncoder().encode(message)
        XCTAssertEqual(try JSONDecoder().decode(Message.self, from: data).images, [image])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "images")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(Message.self, from: legacyData).images)
    }

    func testDropDecoderRejectsNonImageAndNormalizesPNG() throws {
        XCTAssertThrowsError(try PromptAttachment.decode(Data("not an image".utf8)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 5,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = try PromptAttachment.decode(png)
        XCTAssertEqual(attachment.image.mimeType, "image/png")
        XCTAssertEqual(attachment.image.width, 10)
        XCTAssertEqual(attachment.image.height, 5)
    }
}
