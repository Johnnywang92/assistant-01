import XCTest
@testable import AssistantCore

final class RuleEngineTests: XCTestCase {
    let engine = RuleEngine()

    private func parcel(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> ParcelInfo? {
        guard case .parcel(let p) = engine.parse(text) else {
            XCTFail("expected parcel, got \(engine.parse(text))", file: file, line: line)
            return nil
        }
        return p
    }

    // MARK: - 到件

    func testCainiaoStation() {
        let p = parcel("【菜鸟驿站】您的中通包裹已到阳光小区菜鸟驿站，请凭取件码 8-2-3021 及时取件，如有疑问请联系13800000000")
        XCTAssertEqual(p?.pickupCodes, ["8-2-3021"])
        XCTAssertEqual(p?.courier, "中通")
        XCTAssertEqual(p?.station, "菜鸟驿站")
        XCTAssertEqual(p?.location, "阳光小区菜鸟驿站")
    }

    func testFengchaoLocker() {
        let p = parcel("【丰巢】您的顺丰快递已存入科技路3号丰巢柜，取件码12345678，请24小时内取件，超时将收取保管费。")
        XCTAssertEqual(p?.pickupCodes, ["12345678"])
        XCTAssertEqual(p?.courier, "顺丰")
        XCTAssertEqual(p?.station, "丰巢")
        XCTAssertEqual(p?.location, "科技路3号丰巢柜")
    }

    func testFengchaoSpecificCabinetNumber() {
        let p = parcel("【丰巢】凭取件码75277806至安阁苑南区进门左侧丰巢柜3号柜取件。快递员及畅存规则p.fcbox.com/PxG8s")
        XCTAssertEqual(p?.pickupCodes, ["75277806"])
        XCTAssertEqual(p?.station, "丰巢")
        XCTAssertEqual(p?.location, "安阁苑南区进门左侧丰巢柜3号柜")
    }

    func testCainiaoStoreFormat() {
        let p = parcel("【菜鸟驿站】请凭3-5-7016到上海曹杨二村北杨园店取您的邮政生鲜件包裹，请尽快领取哦。")
        XCTAssertEqual(p?.pickupCodes, ["3-5-7016"])
        XCTAssertEqual(p?.courier, "邮政")
        XCTAssertEqual(p?.station, "菜鸟驿站")
        XCTAssertEqual(p?.location, "上海曹杨二村北杨园店")
    }

    func testTuxiWithFullwidthColon() {
        let p = parcel("【兔喜生活】取件码为：A12-3-4567，请到幸福里兔喜超市取件，营业时间8:00-21:00")
        XCTAssertEqual(p?.pickupCodes, ["A12-3-4567"])
        XCTAssertEqual(p?.station, "兔喜生活")
        XCTAssertEqual(p?.location, "幸福里兔喜超市")
    }

    func testPingKeyword() {
        let p = parcel("【妈妈驿站】凭6-3-2201到东门妈妈驿站取件")
        XCTAssertEqual(p?.pickupCodes, ["6-3-2201"])
        XCTAssertEqual(p?.location, "东门妈妈驿站")
    }

    func testMultipleCodes() {
        let p = parcel("【菜鸟驿站】您有2个包裹在花园路菜鸟驿站，取件码：1-2-3001、1-2-3002，请尽快领取")
        XCTAssertEqual(p?.pickupCodes, ["1-2-3001", "1-2-3002"])
        XCTAssertEqual(p?.location, "花园路菜鸟驿站")
    }

    func testIgnorePhraseDoesNotTriggerPickedUp() {
        let p = parcel("【菜鸟驿站】您的包裹已到南门驿站，取件码5-1-1102，如已取件请忽略本短信。")
        XCTAssertEqual(p?.pickupCodes, ["5-1-1102"])
    }

    func testLocationAfterTimePhrase() {
        let p = parcel("【京东】您的订单请在24小时内到3号楼京东快递柜取件，取件码：654321")
        XCTAssertEqual(p?.pickupCodes, ["654321"])
        XCTAssertEqual(p?.courier, "京东")
        XCTAssertEqual(p?.location, "3号楼京东快递柜")
    }

    func testFullwidthDigits() {
        let p = parcel("【菜鸟驿站】取件码８－２－３０２１，请到北门菜鸟驿站取件")
        XCTAssertEqual(p?.pickupCodes, ["8-2-3021"])
    }

    // MARK: - 已取件

    func testPickedUp() {
        guard case .pickedUp(let c) = engine.parse("【菜鸟驿站】您的包裹已从阳光小区菜鸟驿站取出，取件码8-2-3021，感谢使用") else {
            return XCTFail()
        }
        XCTAssertEqual(c.pickupCodes, ["8-2-3021"])
        XCTAssertEqual(c.location, "阳光小区菜鸟驿站")
    }

    func testPickedUpLocker() {
        guard case .pickedUp(let c) = engine.parse("【丰巢】您的快递已被取走，如非本人操作请联系客服") else {
            return XCTFail()
        }
        XCTAssertEqual(c.station, "丰巢")
        XCTAssertTrue(c.pickupCodes.isEmpty)
    }

    func testSignedWithoutCode() {
        guard case .pickedUp = engine.parse("【顺丰速运】您的快件已签收，感谢使用顺丰") else {
            return XCTFail()
        }
    }

    // MARK: - 流量

    func testChinaMobileData() {
        guard case .dataUsage(let d) = engine.parse(
            "【中国移动】尊敬的客户，截至10月9日15时，您本月套餐内通用流量已使用18.5GB，剩余1.5GB。",
            sender: "10086"
        ) else { return XCTFail() }
        XCTAssertEqual(d.operatorName, "中国移动")
        XCTAssertEqual(d.usedMB ?? 0, 18.5 * 1024, accuracy: 0.01)
        XCTAssertEqual(d.remainingMB ?? 0, 1.5 * 1024, accuracy: 0.01)
        XCTAssertEqual(d.effectiveUsedPercent ?? 0, 92.5, accuracy: 0.01)
    }

    func testUnicomPercent() {
        guard case .dataUsage(let d) = engine.parse("【中国联通】您的国内通用流量已使用80%，剩余流量512MB，可回复KTLL办理流量包。") else {
            return XCTFail()
        }
        XCTAssertEqual(d.operatorName, "中国联通")
        XCTAssertEqual(d.usedPercent, 80)
        XCTAssertEqual(d.remainingMB, 512)
    }

    func testTelecomBySender() {
        guard case .dataUsage(let d) = engine.parse("您好，您本月流量还剩2.3G，话费余额35.2元。", sender: "10000") else {
            return XCTFail()
        }
        XCTAssertEqual(d.operatorName, "中国电信")
        XCTAssertEqual(d.remainingMB ?? 0, 2.3 * 1024, accuracy: 0.01)
    }

    // MARK: - 信用卡账单

    func testCreditCardBill() {
        let text = "【招商银行】您尾号8888的信用卡本期账单金额为人民币3280.50元，到期还款日为10月25日，最低还款额328.00元。"
        guard case .creditCardBill(let b) = engine.parse(text) else {
            return XCTFail("Expected creditCardBill, got \(engine.parse(text))")
        }
        XCTAssertEqual(b.bankName, "招商银行")
        XCTAssertEqual(b.cardTail, "8888")
        XCTAssertEqual(b.amount, 3280.50)
        XCTAssertEqual(b.dueDateString, "10月25日")
        XCTAssertEqual(b.minPayment, 328.00)
    }

    // MARK: - 忽略

    func testVerificationIgnored() {
        XCTAssertEqual(engine.parse("【某银行】您的验证码为 834921，5分钟内有效，请勿泄露。"), .ignored)
    }

    func testUnknown() {
        XCTAssertEqual(engine.parse("明天下午三点开会，记得带电脑"), .unknown)
    }
}

final class ParcelMatcherTests: XCTestCase {
    let a = PendingParcel(id: UUID(), pickupCode: "8-2-3021", courier: "中通", station: "菜鸟驿站", location: "阳光小区菜鸟驿站")
    let b = PendingParcel(id: UUID(), pickupCode: "12345678", courier: "顺丰", station: "丰巢", location: "科技路3号丰巢柜")

    func testMatchByCode() {
        let ids = ParcelMatcher.matchPickup(PickupConfirmation(pickupCodes: ["8-2-3021"]), pending: [a, b])
        XCTAssertEqual(ids, [a.id])
    }

    func testMatchByStationUnique() {
        let ids = ParcelMatcher.matchPickup(PickupConfirmation(station: "丰巢"), pending: [a, b])
        XCTAssertEqual(ids, [b.id])
    }

    func testAmbiguousReturnsEmpty() {
        let c = PendingParcel(id: UUID(), pickupCode: "99999999", courier: "京东", station: "丰巢", location: "科技路3号丰巢柜")
        let ids = ParcelMatcher.matchPickup(PickupConfirmation(location: "科技路3号丰巢柜"), pending: [a, b, c])
        XCTAssertEqual(ids, [])
    }

    func testDuplicate() {
        let info = ParcelInfo(pickupCodes: ["8-2-3021"], station: "菜鸟驿站", location: "阳光小区菜鸟驿站")
        XCTAssertEqual(ParcelMatcher.duplicate(code: "8-2-3021", info: info, pending: [a, b])?.id, a.id)
        XCTAssertNil(ParcelMatcher.duplicate(code: "8-2-3022", info: info, pending: [a, b]))
    }

    func testInboxEntries() {
        let content = "===MSG===\n短信一\n===MSG===\n\n===MSG===\n短信二\n第二行\n"
        XCTAssertEqual(InboxFormat.entries(from: content), ["短信一", "短信二\n第二行"])
    }
}
