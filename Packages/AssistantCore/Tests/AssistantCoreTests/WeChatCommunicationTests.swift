import XCTest
@testable import AssistantCore

final class WeChatCommunicationTests: XCTestCase {
    func testWeChatVideoRecognition() {
        XCTAssertTrue(WeChatCommunicationHelper.isWeChatCommunication(title: "给妈妈打微信视频"))
        XCTAssertEqual(WeChatCommunicationHelper.communicationKind(title: "给妈妈打微信视频"), .video)

        XCTAssertTrue(WeChatCommunicationHelper.isWeChatCommunication(title: "晚上打个视频", detail: "和家里视频通话"))
        XCTAssertEqual(WeChatCommunicationHelper.communicationKind(title: "晚上打个视频"), .video)
    }

    func testWeChatAudioAndMessageRecognition() {
        XCTAssertTrue(WeChatCommunicationHelper.isWeChatCommunication(title: "微信语音问房东水电费"))
        XCTAssertEqual(WeChatCommunicationHelper.communicationKind(title: "微信语音问房东水电费"), .audio)

        XCTAssertTrue(WeChatCommunicationHelper.isWeChatCommunication(title: "微信回复李老师"))
        XCTAssertEqual(WeChatCommunicationHelper.communicationKind(title: "微信回复李老师"), .message)
    }

    func testNonWeChatTasksAreNotRecognized() {
        XCTAssertFalse(WeChatCommunicationHelper.isWeChatCommunication(title: "去菜鸟驿站取快递"))
        XCTAssertFalse(WeChatCommunicationHelper.isWeChatCommunication(title: "购买微波炉和电饭煲"))
        XCTAssertFalse(WeChatCommunicationHelper.isWeChatCommunication(title: "晚上跑步五公里"))
    }

    func testURLSchemeAndIcons() {
        XCTAssertEqual(WeChatCommunicationHelper.weChatURLScheme, "weixin://")
        XCTAssertEqual(WeChatCommunicationHelper.CommunicationKind.video.iconName, "video.fill")
        XCTAssertEqual(WeChatCommunicationHelper.CommunicationKind.audio.iconName, "phone.fill")
        XCTAssertEqual(WeChatCommunicationHelper.CommunicationKind.message.iconName, "bubble.left.and.bubble.right.fill")
    }
}
