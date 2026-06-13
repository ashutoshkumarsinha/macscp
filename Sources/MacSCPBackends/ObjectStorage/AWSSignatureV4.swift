// AWSSignatureV4.swift
//
// WHAT THIS FILE DOES
// -------------------
// Signs HTTP requests for AWS S3-compatible APIs using Signature Version 4.
// S3MultipartUpload and the S3 backend call sign to attach auth headers.
//
import Crypto
import Foundation
import MacSCPCore

enum AWSSignatureV4 {
    struct SignedRequest {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: Data?
    }

    static func sign(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        credentials: ObjectStorageCredentials,
        layout: ObjectStorageLayout
    ) throws -> SignedRequest {
        let now = Date()
        let amzDate = timestamp(now)
        let dateStamp = String(amzDate.prefix(8))
        let payloadHash = sha256Hex(body ?? Data())

        var signedHeaders = headers
        signedHeaders["host"] = layout.endpointHost
        signedHeaders["x-amz-content-sha256"] = payloadHash
        signedHeaders["x-amz-date"] = amzDate

        let canonicalURI = path.isEmpty ? "/" : path
        let canonicalQuery = canonicalQueryString(queryItems)
        let canonicalHeaders = canonicalHeadersString(signedHeaders)
        let signedHeaderNames = signedHeaders.keys.map { $0.lowercased() }.sorted().joined(separator: ";")

        let canonicalRequest = [
            method.uppercased(),
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaderNames,
            payloadHash,
        ].joined(separator: "\n")

        let service = "s3"
        let credentialScope = "\(dateStamp)/\(layout.region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = deriveSigningKey(
            secret: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: layout.region,
            service: service
        )
        let signature = hmacHex(key: signingKey, data: Data(stringToSign.utf8))
        let authorization = """
AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaderNames), Signature=\(signature)
"""

        var finalHeaders = signedHeaders
        finalHeaders["Authorization"] = authorization

        var components = URLComponents()
        components.scheme = layout.useHTTPS ? "https" : "http"
        components.host = layout.endpointHost
        components.path = canonicalURI
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw BackendError.invalidConfiguration("Invalid object storage URL")
        }

        return SignedRequest(url: url, method: method.uppercased(), headers: finalHeaders, body: body)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func canonicalQueryString(_ items: [URLQueryItem]) -> String {
        items
            .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
            .map { item in
                let name = urlEncode(item.name)
                let value = urlEncode(item.value ?? "")
                return "\(name)=\(value)"
            }
            .joined(separator: "&")
    }

    private static func canonicalHeadersString(_ headers: [String: String]) -> String {
        headers
            .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)\n" }
            .joined()
    }

    private static func deriveSigningKey(secret: String, dateStamp: String, region: String, service: String) -> SymmetricKey {
        let kSecret = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        let kDate = hmac(key: kSecret, data: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        return hmac(key: kService, data: Data("aws4_request".utf8))
    }

    private static func hmac(key: SymmetricKey, data: Data) -> SymmetricKey {
        SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    private static func hmacHex(key: SymmetricKey, data: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
