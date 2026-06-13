// ObjectStorageLayout.swift
//
// WHAT THIS FILE DOES
// -------------------
// Credentials, endpoint layout, and path helpers for S3- and GCS-compatible storage.
// Object-storage backends and AWSSignatureV4 use ObjectStorageLayout for bucket URLs.
//
import Foundation

public struct ObjectStorageCredentials: Sendable, Equatable {
    public var accessKeyID: String
    public var secretAccessKey: String

    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}

public struct ObjectStorageLayout: Sendable, Equatable {
    public enum Provider: String, Sendable {
        case aws
        case gcs
    }

    public var provider: Provider
    public var bucket: String
    public var prefix: String
    public var region: String
    public var endpointHost: String
    public var useHTTPS: Bool

    public init(
        provider: Provider,
        bucket: String,
        prefix: String = "",
        region: String,
        endpointHost: String,
        useHTTPS: Bool = true
    ) {
        self.provider = provider
        self.bucket = bucket
        self.prefix = ObjectStorageLayout.normalizePrefix(prefix)
        self.region = region
        self.endpointHost = endpointHost
        self.useHTTPS = useHTTPS
    }

    public static func resolve(from configuration: SessionConfiguration, provider: Provider) throws -> ObjectStorageLayout {
        guard let password = configuration.password, !password.isEmpty else {
            throw BackendError.authenticationFailed("Access key secret required")
        }
        guard !configuration.username.isEmpty else {
            throw BackendError.authenticationFailed("Access key ID required")
        }

        let bucket: String
        let prefix: String
        if let configuredBucket = configuration.advanced.cloudBucket, !configuredBucket.isEmpty {
            bucket = configuredBucket
            prefix = configuration.initialRemotePath
        } else {
            let parts = configuration.initialRemotePath
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard let first = parts.first else {
                throw BackendError.invalidConfiguration("Object storage path must start with /bucket[/prefix]")
            }
            bucket = first
            prefix = parts.dropFirst().joined(separator: "/")
        }

        let region = configuration.advanced.cloudRegion ?? defaultRegion(for: provider)
        let endpointHost: String
        if configuration.host.isEmpty || configuration.host == "localhost" {
            endpointHost = defaultEndpoint(for: provider, region: region)
        } else {
            endpointHost = configuration.host
        }

        return ObjectStorageLayout(
            provider: provider,
            bucket: bucket,
            prefix: prefix,
            region: region,
            endpointHost: endpointHost,
            useHTTPS: configuration.port == 443 || configuration.port == 0
        )
    }

    public func objectKey(for remotePath: String) -> String {
        let trimmed = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if prefix.isEmpty { return trimmed }
        if trimmed.isEmpty { return prefix }
        return "\(prefix)/\(trimmed)"
    }

    public func remotePath(for objectKey: String) -> String {
        let key = objectKey
        if prefix.isEmpty { return key }
        if key.hasPrefix(prefix + "/") {
            return String(key.dropFirst(prefix.count + 1))
        }
        if key == prefix { return "" }
        return key
    }

    public static func normalizePrefix(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func defaultRegion(for provider: Provider) -> String {
        switch provider {
        case .aws: return "us-east-1"
        case .gcs: return "auto"
        }
    }

    private static func defaultEndpoint(for provider: Provider, region: String) -> String {
        switch provider {
        case .aws:
            if region == "us-east-1" { return "s3.amazonaws.com" }
            return "s3.\(region).amazonaws.com"
        case .gcs:
            return "storage.googleapis.com"
        }
    }
}
