// postern-hello: Windows Hello for Postern's core. It never decides anything: it creates the key once, and signs the
// challenge the core gives it when you approve an email or a deletion. Windows draws the prompt (face, fingerprint or
// PIN) and the TPM signs; the core checks the signature against the public key it pinned at setup.
//
//   postern-hello register        prints the new credential's public key (SubjectPublicKeyInfo, base64)
//   postern-hello sign <base64>   prints the signature of the challenge (base64)
//
// Exit codes: 0 done, 2 Windows Hello is not set up, 3 the user cancelled or failed, 4 bad arguments.

#include <cstdio>
#include <cwchar>
#include <string>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Credentials.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <winrt/Windows.Security.Cryptography.Core.h>
#include <winrt/Windows.Storage.Streams.h>

using namespace winrt;
using namespace Windows::Security::Credentials;
using namespace Windows::Security::Cryptography;
using namespace Windows::Security::Cryptography::Core;

static const wchar_t *kCredential = L"ch.rubencatalao.postern.approvals";

static int print(const hstring &text) {
    std::wstring line(text);
    wprintf(L"%ls\n", line.c_str());
    fflush(stdout);
    return 0;
}

int wmain(int argc, wchar_t **argv) {
    init_apartment();
    if (argc < 2) return 4;
    std::wstring command(argv[1]);
    try {
        if (!KeyCredentialManager::IsSupportedAsync().get()) return 2;
        if (command == L"register") {
            auto created = KeyCredentialManager::RequestCreateAsync(kCredential, KeyCredentialCreationOption::ReplaceExisting).get();
            if (created.Status() != KeyCredentialStatus::Success) return 3;
            auto key = created.Credential().RetrievePublicKey(CryptographicPublicKeyBlobType::X509SubjectPublicKeyInfo);
            return print(CryptographicBuffer::EncodeToBase64String(key));
        }
        if (command == L"sign" && argc >= 3) {
            auto opened = KeyCredentialManager::OpenAsync(kCredential).get();
            if (opened.Status() != KeyCredentialStatus::Success) return 2;
            auto challenge = CryptographicBuffer::DecodeFromBase64String(argv[2]);
            auto signed_ = opened.Credential().RequestSignAsync(challenge).get();
            if (signed_.Status() != KeyCredentialStatus::Success) return 3;
            return print(CryptographicBuffer::EncodeToBase64String(signed_.Result()));
        }
    } catch (hresult_error const &) {
        return 3;
    }
    return 4;
}
