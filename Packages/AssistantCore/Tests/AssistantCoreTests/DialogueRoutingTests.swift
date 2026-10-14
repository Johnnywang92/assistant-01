import XCTest
@testable import AssistantCore

final class DialogueRoutingTests: XCTestCase {

    // MARK: - 闲聊旁路判定测试

    func testPureGreetingsAreSmallTalk() {
        XCTAssertTrue(DialogueRouter.isSmallTalk("你好"))
        XCTAssertTrue(DialogueRouter.isSmallTalk("小助你好"))
        XCTAssertTrue(DialogueRouter.isSmallTalk("早上好"))
        XCTAssertTrue(DialogueRouter.isSmallTalk("晚安"))
        XCTAssertTrue(DialogueRouter.isSmallTalk("hi"))
        XCTAssertTrue(DialogueRouter.isSmallTalk("hello"))
    }

    func testGratitudeAndIdentityAreSmallTalk() {
        XCTAssertTrue(DialogueRouter.isSmallTalk("谢谢你"))
        XCTAssertTrue(DialogueRouter.isSmallTalk("辛苦了小助"))
        XCTAssertTrue(DialogueRouter.isSmallTalk("你是谁"))
        XCTAssertTrue(DialogueRouter.isSmallTalk("你能做什么"))
        XCTAssertTrue(DialogueRouter.isSmallTalk("讲个笑话"))
        XCTAssertTrue(DialogueRouter.isSmallTalk("好无聊啊"))
    }

    func testGreetingsWithDomainTasksAreNotSmallTalk() {
        // 含有明确生活业务词的输入，绝不能被闲聊旁路吃掉
        XCTAssertFalse(DialogueRouter.isSmallTalk("早上好，今天有什么快递吗"))
        XCTAssertFalse(DialogueRouter.isSmallTalk("你好，帮我记一笔账"))
        XCTAssertFalse(DialogueRouter.isSmallTalk("你好，提醒我下午三点开会"))
        XCTAssertFalse(DialogueRouter.isSmallTalk("我现在该干嘛"))
        XCTAssertFalse(DialogueRouter.isSmallTalk("今天要做什么"))
    }

    // MARK: - 规则直出判定测试

    func testExplicitQueriesRouteToRules() {
        XCTAssertTrue(DialogueRouter.shouldRouteQueryToRules("我有哪些快递"))
        XCTAssertTrue(DialogueRouter.shouldRouteQueryToRules("今天花了多少钱"))
        XCTAssertTrue(DialogueRouter.shouldRouteQueryToRules("昨天消费了什么"))
        XCTAssertTrue(DialogueRouter.shouldRouteQueryToRules("身份证放在哪里"))
        XCTAssertTrue(DialogueRouter.shouldRouteQueryToRules("今天有什么待办"))
        XCTAssertTrue(DialogueRouter.shouldRouteQueryToRules("出门防丢清单有哪些"))
    }

    func testOpenEndedQuestionsDoNotRouteToRules() {
        // 开放性问答或生活建议不应被规则拦截
        XCTAssertFalse(DialogueRouter.shouldRouteQueryToRules("你好呀"))
        XCTAssertFalse(DialogueRouter.shouldRouteQueryToRules("今天天气真好"))
        XCTAssertFalse(DialogueRouter.shouldRouteQueryToRules("我想学Python，每天半小时"))
        XCTAssertFalse(DialogueRouter.shouldRouteQueryToRules("讲个笑话吧"))
    }
}
