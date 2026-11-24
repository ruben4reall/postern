import Testing
@testable import PosternBridge

@Suite struct ProtonRefusalTests {
    @Test func protonsTemporaryBlockIsToldApartFromItsHourlyLimit() {
        let block = BridgeError.commandFailed("SMTP 554 5.0.0 Error: transaction failed, blame it on the weather: Your account is temporarily banned from sending")
        let limit = BridgeError.commandFailed("SMTP 554 5.0.0 Error: transaction failed, blame it on the weather: Hourly external limit reached")
        let size = BridgeError.commandFailed("SMTP 552 Message size limit exceeded")
        #expect(block.isProtonSendingBlock && !block.isProtonSendingLimit)
        #expect(limit.isProtonSendingLimit && !limit.isProtonSendingBlock)
        #expect(!size.isProtonSendingLimit && !size.isProtonSendingBlock)
    }
}
