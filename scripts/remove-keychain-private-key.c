#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>

#include <stdio.h>
#include <string.h>

static void print_status_error(const char *operation, OSStatus status) {
    CFStringRef message = SecCopyErrorMessageString(status, NULL);
    char buffer[1024] = {0};
    if (message != NULL) {
        CFStringGetCString(message, buffer, sizeof(buffer), kCFStringEncodingUTF8);
        CFRelease(message);
    }
    fprintf(stderr, "%s failed: %d%s%s\n", operation, (int)status,
            buffer[0] == '\0' ? "" : " — ", buffer);
}

static int normalize_sha1(const char *input, char output[CC_SHA1_DIGEST_LENGTH * 2 + 1]) {
    size_t output_index = 0;
    for (const char *cursor = input; *cursor != '\0'; cursor++) {
        char character = *cursor;
        if (character == ':' || character == ' ' || character == '\t') {
            continue;
        }
        if (!((character >= '0' && character <= '9')
              || (character >= 'a' && character <= 'f')
              || (character >= 'A' && character <= 'F'))
            || output_index >= CC_SHA1_DIGEST_LENGTH * 2) {
            return 0;
        }
        output[output_index++] = (character >= 'a' && character <= 'f')
            ? (char)(character - 'a' + 'A')
            : character;
    }
    output[output_index] = '\0';
    return output_index == CC_SHA1_DIGEST_LENGTH * 2;
}

static int certificate_sha1(SecCertificateRef certificate,
                            char output[CC_SHA1_DIGEST_LENGTH * 2 + 1]) {
    CFDataRef data = SecCertificateCopyData(certificate);
    if (data == NULL) {
        return 0;
    }

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(CFDataGetBytePtr(data), (CC_LONG)CFDataGetLength(data), digest);
    CFRelease(data);

    for (size_t index = 0; index < CC_SHA1_DIGEST_LENGTH; index++) {
        snprintf(output + (index * 2), 3, "%02X", digest[index]);
    }
    output[CC_SHA1_DIGEST_LENGTH * 2] = '\0';
    return 1;
}

static SecIdentityRef copy_matching_identity(SecKeychainRef keychain,
                                             const char *expected_fingerprint) {
    SecIdentitySearchRef search = NULL;
    OSStatus status = SecIdentitySearchCreate(keychain, CSSM_KEYUSE_SIGN, &search);
    if (status != errSecSuccess) {
        print_status_error("SecIdentitySearchCreate", status);
        return NULL;
    }

    SecIdentityRef match = NULL;
    SecIdentityRef candidate = NULL;
    while (SecIdentitySearchCopyNext(search, &candidate) == errSecSuccess) {
        SecCertificateRef certificate = NULL;
        if (SecIdentityCopyCertificate(candidate, &certificate) == errSecSuccess) {
            char actual_fingerprint[CC_SHA1_DIGEST_LENGTH * 2 + 1] = {0};
            if (certificate_sha1(certificate, actual_fingerprint)
                && strcmp(actual_fingerprint, expected_fingerprint) == 0) {
                if (match != NULL) {
                    fprintf(stderr, "More than one identity matched the expected fingerprint.\n");
                    CFRelease(certificate);
                    CFRelease(candidate);
                    CFRelease(match);
                    CFRelease(search);
                    return NULL;
                }
                match = candidate;
                CFRetain(match);
            }
            CFRelease(certificate);
        }
        CFRelease(candidate);
        candidate = NULL;
    }
    CFRelease(search);
    return match;
}

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s KEYCHAIN EXPECTED_SHA1\n", argv[0]);
        return 64;
    }

    char expected_fingerprint[CC_SHA1_DIGEST_LENGTH * 2 + 1] = {0};
    if (!normalize_sha1(argv[2], expected_fingerprint)) {
        fprintf(stderr, "Expected SHA-1 fingerprint must contain exactly 40 hexadecimal digits.\n");
        return 64;
    }

    SecKeychainRef keychain = NULL;
    OSStatus status = SecKeychainOpen(argv[1], &keychain);
    if (status != errSecSuccess) {
        print_status_error("SecKeychainOpen", status);
        return 1;
    }

    SecIdentityRef identity = copy_matching_identity(keychain, expected_fingerprint);
    if (identity == NULL) {
        fprintf(stderr, "No unique identity matched the expected fingerprint.\n");
        CFRelease(keychain);
        return 2;
    }

    SecKeyRef private_key = NULL;
    status = SecIdentityCopyPrivateKey(identity, &private_key);
    if (status == errSecSuccess) {
        // Delete only the private-key item. The certificate and its trust
        // settings stay intact, so interruption cannot create a trust gap.
        status = SecKeychainItemDelete((SecKeychainItemRef)private_key);
    }

    if (status != errSecSuccess) {
        print_status_error("private-key deletion", status);
    }
    if (private_key != NULL) {
        CFRelease(private_key);
    }
    CFRelease(identity);
    CFRelease(keychain);
    return status == errSecSuccess ? 0 : 1;
}
