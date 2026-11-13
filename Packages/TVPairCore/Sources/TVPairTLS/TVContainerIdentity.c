#include "TVPairTLS.h"
#include <OpenSSL/evp.h>
#include <OpenSSL/rsa.h>
#include <OpenSSL/x509.h>
#include <OpenSSL/x509v3.h>
#include <OpenSSL/pkcs12.h>
#include <OpenSSL/rand.h>
#include <OpenSSL/crypto.h>

static int add_extension(X509 *certificate, int nid, const char *value) {
    X509_EXTENSION *extension = X509V3_EXT_conf_nid(NULL, NULL, nid, (char *)value);
    if (!extension) return 0;
    int result = X509_add_ext(certificate, extension, -1);
    X509_EXTENSION_free(extension);
    return result == 1;
}

int tvp_container_identity(const char *password, uint8_t **output, size_t *length) {
    if (!password || !password[0] || !output || !length) return 0;
    *output = NULL; *length = 0;
    int result = 0;
    EVP_PKEY_CTX *context = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, NULL);
    EVP_PKEY *key = NULL;
    X509 *certificate = NULL;
    PKCS12 *container = NULL;
    BIGNUM *number = NULL;
    ASN1_INTEGER *integer = NULL;
    unsigned char *encoded = NULL;
    int encoded_length = 0;
    unsigned char serial[16];
    if (!context || EVP_PKEY_keygen_init(context) <= 0 ||
        EVP_PKEY_CTX_set_rsa_keygen_bits(context, 2048) <= 0 ||
        EVP_PKEY_keygen(context, &key) <= 0 || !(certificate = X509_new()) ||
        RAND_bytes(serial, sizeof(serial)) != 1) goto cleanup;
    serial[0] &= 0x7f; serial[15] |= 1;
    number = BN_bin2bn(serial, sizeof(serial), NULL);
    integer = number ? BN_to_ASN1_INTEGER(number, NULL) : NULL;
    if (!integer || X509_set_serialNumber(certificate, integer) != 1 ||
        X509_set_version(certificate, 2) != 1 ||
        !X509_gmtime_adj(X509_getm_notBefore(certificate), -300) ||
        !X509_gmtime_adj(X509_getm_notAfter(certificate), 5L * 365 * 24 * 60 * 60) ||
        X509_set_pubkey(certificate, key) != 1) goto cleanup;
    X509_NAME *name = X509_get_subject_name(certificate);
    if (!name || X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
        (const unsigned char *)"SideTVStore transfer", -1, -1, 0) != 1 ||
        X509_set_issuer_name(certificate, name) != 1 ||
        !add_extension(certificate, NID_basic_constraints, "critical,CA:FALSE") ||
        !add_extension(certificate, NID_key_usage, "critical,digitalSignature,keyEncipherment") ||
        !add_extension(certificate, NID_ext_key_usage, "serverAuth,clientAuth") ||
        X509_sign(certificate, key, EVP_sha256()) <= 0) goto cleanup;
    // Apple-compatible wrapping, independent of SHA-256 certificate signatures
    // and TLS 1.3. The random wrapping password and P12 only live in Keychain.
    container = PKCS12_create(password, "SideTVStore transfer", key, certificate, NULL,
        NID_pbe_WithSHA1And3_Key_TripleDES_CBC, NID_pbe_WithSHA1And3_Key_TripleDES_CBC, 2048, 2048, 0);
    if (!container || PKCS12_set_mac(container, password, -1, NULL, 0, 2048, EVP_sha1()) != 1 ||
        (encoded_length = i2d_PKCS12(container, &encoded)) <= 0) goto cleanup;
    *output = encoded; *length = (size_t)encoded_length;
    encoded = NULL; result = 1;
cleanup:
    OPENSSL_clear_free(encoded, encoded_length > 0 ? (size_t)encoded_length : 0);
    ASN1_INTEGER_free(integer); BN_free(number); PKCS12_free(container);
    X509_free(certificate); EVP_PKEY_free(key); EVP_PKEY_CTX_free(context);
    return result;
}

void tvp_container_identity_free(uint8_t *output, size_t length) { OPENSSL_clear_free(output, length); }
