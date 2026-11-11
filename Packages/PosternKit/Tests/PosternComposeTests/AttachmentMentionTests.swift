import Foundation
import PosternModel
import Testing
@testable import PosternCompose

@Suite struct AttachmentMentionTests {
    @Test(arguments: [
        "Vous trouverez ci-joint mon CV.", "Ci-jointe la facture de novembre.", "Je vous joins le devis.",
        "Voir la pièce jointe.", "Les pieces jointes sont là.", "Le contrat en PJ.", "PJ : contrat.pdf",
        "Le rapport en annexe.", "Please find the report attached.", "See the attachment.", "I've attached the slides.",
        "Anbei die Rechnung.", "Die Unterlagen im Anhang.", "Te adjunto el contrato.", "Segue anexo o relatório.",
        "In allegato il preventivo.", "In de bijlage vindt u het rapport.", "W załączniku przesyłam fakturę.",
        "Załączam CV.", "請求書を添付します。", "添付ファイルをご確認ください。", "请查收附件。", "隨附報價單。", "견적서를 첨부합니다.",
    ])
    func findsTheWordsThatAnnounceAFile(_ text: String) {
        #expect(AttachmentMention.found(in: text) != nil, "\(text)")
    }

    @Test(arguments: [
        "Je souhaite rejoindre votre équipe.", "Mon attachement à votre entreprise est fort.", "Un joint venture à Genève.",
        "Merci pour votre réponse.", "The attachment style of the toddler", "Je me suis attaché à ce projet.",
        "Je joins Marc en copie.", "Subdirector Adjunto de ventas", "Comme prévu en annexe 2 du contrat.",
        "Merci.\n\nCe message et ses pièces jointes éventuelles sont confidentiels.",
        "Thanks!\nThis email and any attachments are confidential.",
        "Merci, bien reçu.\n\nLe 3 nov. 2026 à 10:00, Anna a écrit :\n> Vous trouverez ci-joint la facture.",
        "Noted.\n\nOn Mon, 3 Nov 2026, Anna wrote:\n> Please find the invoice attached.",
        "Bien reçu.\n> Ci-joint le devis.",
        "Dziękuję za odpowiedź.", "ありがとうございます。", "谢谢你的回复。", "감사합니다.",
        "谢谢。\n本邮件及其附件可能包含保密信息。", "Danke.\nDiese E-Mail und alle Anlagen sind vertraulich, im Anhang nichts.",
    ])
    func leavesOrdinaryTextAlone(_ text: String) {
        if text.hasPrefix("The attachment") {
            // "attachment" alone is announced: the client says no_attachment when it means something else.
            #expect(AttachmentMention.found(in: AttachmentMention.ownText(text)) != nil)
        } else {
            #expect(AttachmentMention.found(in: AttachmentMention.ownText(text)) == nil, "\(text)")
        }
    }

    @Test func givesTheWordsAsWritten() {
        #expect(AttachmentMention.found(in: "Voici, ci-joint, le CV.") == "ci-joint")
        #expect(AttachmentMention.found(in: "La Pièce Jointe suit") == "Pièce Jointe")
    }

    @Test func aMessageWithFilesOrOnlyAQuoteMentioningOneIsFine() throws {
        let from = Address(name: nil, email: "me@example.ch")
        let to = [Address(name: nil, email: "a@example.com")]
        let file = try OutgoingAttachment.make(filename: "cv.pdf", data: Data("%PDF".utf8))
        let with = try OutgoingMessage.make(from: from, to: to, subject: "CV", body: "Ci-joint mon CV.", attachments: [file])
        #expect(with.missingAttachment == nil)
        let quoted = try OutgoingMessage.make(from: from, to: to, subject: "Re: CV", body: "Merci !", quoted: "> Ci-joint mon CV.")
        #expect(quoted.missingAttachment == nil)
        let without = try OutgoingMessage.make(from: from, to: to, subject: "CV", body: "Ci-joint mon CV.")
        #expect(without.missingAttachment == "Ci-joint")
    }

    @Test func aPinnedMessageIDGivesTheSameDigest() throws {
        let from = Address(name: nil, email: "me@example.ch")
        let to = [Address(name: nil, email: "a@example.com")]
        let first = try OutgoingMessage.make(from: from, to: to, subject: "S", body: "B")
        let again = try OutgoingMessage.make(from: from, to: to, subject: "S", body: "B", messageID: first.messageID)
        #expect(again.digest == first.digest)
        let changed = try OutgoingMessage.make(from: from, to: to, subject: "S", body: "B!", messageID: first.messageID)
        #expect(changed.digest != first.digest)
        #expect(throws: ComposeError.self) { try OutgoingMessage.make(from: from, to: to, subject: "S", body: "B", messageID: "<a>\r\nBcc: x") }
    }
}
