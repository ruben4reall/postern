import Testing
@testable import PosternText

@Suite struct EncodedWordsTests {
    @Test func decodesBase64UTF8() {
        #expect(EncodedWords.decode("=?UTF-8?B?Q2Fmw6kgZGUgbGEgZ2FyZQ==?=") == "Café de la gare")
    }

    @Test func decodesQuotedPrintableLatin1() {
        #expect(EncodedWords.decode("=?ISO-8859-1?Q?Caf=E9_cr=E8me?=") == "Café crème")
    }

    @Test func joinsAdjacentWordsWithoutTheirSeparator() {
        #expect(EncodedWords.decode("=?UTF-8?Q?Bon?= =?UTF-8?Q?jour?= Ruben") == "Bonjour Ruben")
    }

    @Test func keepsPlainTextAndLanguageSuffix() {
        #expect(EncodedWords.decode("Hello =?UTF-8*fr?Q?l=C3=A0?=") == "Hello là")
        #expect(EncodedWords.decode("Plain subject") == "Plain subject")
    }

    @Test func leavesUnknownCharsetAndMalformedWordsAsTheyAre() {
        #expect(EncodedWords.decode("=?X-UNKNOWN?Q?abc?=") == "=?X-UNKNOWN?Q?abc?=")
        #expect(EncodedWords.decode("=?UTF-8?B?***?=") == "=?UTF-8?B?***?=")
    }

    @Test func unfoldsFoldedHeaders() {
        #expect(EncodedWords.decode("Long\r\n subject\r\n\tline") == "Long subject line")
    }
}
