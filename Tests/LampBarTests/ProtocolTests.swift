import XCTest
@testable import LampBar

final class KasaProtocolTests: XCTestCase {
    func testXORRoundTripsAndMatchesTheKnownCipher() {
        let query = #"{"system":{"get_sysinfo":{}}}"#
        let encrypted = KasaXOR.encrypt(query)
        // The autokey cipher starts from 171: '{' (0x7B) ^ 171 = 0xD0.
        XCTAssertEqual(encrypted.first, 0xD0)
        XCTAssertEqual(KasaXOR.decrypt(encrypted), query)
    }

    func testSinglePlugSysinfoGivesOneOutlet() {
        let reply = #"{"system":{"get_sysinfo":{"deviceId":"ABC","alias":"Kitchen Lamp","model":"HS103(US)","relay_state":1}}}"#
        let outlets = KasaXOR.outlets(fromSysinfo: reply, host: "192.168.2.23")
        XCTAssertEqual(outlets.count, 1)
        XCTAssertEqual(outlets[0].id, "ABC")
        XCTAssertNil(outlets[0].childID)
        XCTAssertTrue(outlets[0].isOn)
    }

    func testPowerStripGivesOneOutletPerSocketWithShortOrFullChildIDs() {
        let reply = #"{"system":{"get_sysinfo":{"deviceId":"ABC","alias":"Strip","model":"KP303(US)","children":[{"id":"00","state":1,"alias":"Plug 1"},{"id":"ABC01","state":0,"alias":"Plants Lamp"}]}}}"#
        let outlets = KasaXOR.outlets(fromSysinfo: reply, host: "192.168.2.25")
        XCTAssertEqual(outlets.map(\.id), ["ABC/00", "ABC/01"])
        XCTAssertEqual(outlets.map(\.isOn), [true, false])
        XCTAssertEqual(outlets[1].label, "Plants Lamp · Strip")
    }

    func testRelayCommandAddressesTheStripSocket() {
        XCTAssertEqual(KasaXOR.setRelayCommand(on: true, deviceID: "ABC", childID: nil),
                       #"{"system":{"set_relay_state":{"state":1}}}"#)
        XCTAssertEqual(KasaXOR.setRelayCommand(on: false, deviceID: "ABC", childID: "02"),
                       #"{"context":{"child_ids":["ABC02"]},"system":{"set_relay_state":{"state":0}}}"#)
    }

    func testGarbageSysinfoGivesNoOutlets() {
        XCTAssertTrue(KasaXOR.outlets(fromSysinfo: "not json", host: "1.2.3.4").isEmpty)
    }
}

final class GoveeProtocolTests: XCTestCase {
    func testMessageAndReplyShapes() throws {
        let message = GoveeClient.message("turn", ["value": 1])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: message) as? [String: Any])
        let msg = try XCTUnwrap(json["msg"] as? [String: Any])
        XCTAssertEqual(msg["cmd"] as? String, "turn")
        XCTAssertEqual((msg["data"] as? [String: Any])?["value"] as? Int, 1)

        let reply = GoveeClient.reply(Data(#"{"msg":{"cmd":"devStatus","data":{"onOff":1,"brightness":60}}}"#.utf8))
        XCTAssertEqual(reply?.cmd, "devStatus")
        XCTAssertEqual(reply?.data["brightness"] as? Int, 60)
    }

    func testWhiteModeShowsAWarmColor() {
        let status = GoveeStatus(isOn: true, brightness: 50, color: RGB(r: 0, g: 0, b: 0), kelvin: 2700)
        let shown = status.displayColor
        XCTAssertEqual(shown.r, 255)
        XCTAssertGreaterThan(shown.g, shown.b)
    }
}
