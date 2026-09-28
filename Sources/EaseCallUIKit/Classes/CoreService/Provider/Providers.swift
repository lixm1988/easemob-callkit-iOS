//
//  Providers.swift
//  EaseCallUIKit
//
//  Created by 朱继超 on 7/7/25.
//

import Foundation

/// Profile provider of the ChatUIKit.Only available in Swift language.
public protocol CallUserProfileProvider { //去掉user
    
    /// Coroutine obtains user information asynchronously.
    /// - Parameter profileIds: The corresponding conversation id string array.
    /// - Returns: Array of the conform``ChatUserProfileProtocol`` object.
    func fetchUserProfiles(profileIds: [String]) async -> [CallProfileProtocol]
    
    
    /// Coroutine obtains group information asynchronously.
    /// - Parameter profileIds: The corresponding group id string array.
    /// - Returns: Array of the conform``ChatUserProfileProtocol`` object.
    func fetchGroupProfiles(profileIds: [String]) async -> [CallProfileProtocol]
}

/// /// Profile provider of the ChatUIKit.Only available in Objective-C language.
@objc public protocol CallUserProfileProviderOC: NSObjectProtocol {
    
    /// Need to obtain the list display information on the current screen.
    /// - Parameters:
    ///   - profileIds: The corresponding conversation id string array.
    ///   - completion: Callback,obtain Array of the ``ChatUserProfileProtocol`` object.
    func fetchProfiles(profileIds: [String],completion: @escaping ([CallProfileProtocol]) -> Void)
    
    /// Need to obtain the group display information on the current screen.
    /// - Parameters:
    ///   - profileIds: The corresponding group id string array.
    ///   - completion: Callback,obtain Array of the ``ChatUserProfileProtocol`` object.
    func fetchGroupProfiles(profileIds: [String],completion: @escaping ([CallProfileProtocol]) -> Void)
}

public struct CallRTCTokenInfo: Sendable {
    /// Legacy credential UID. String-account joins use the UID assigned by RTC instead.
    public let uid: UInt32
    public let token: String
    public let expiration: Int64

    public init(uid: UInt32, token: String, expiration: Int64) {
        self.uid = uid
        self.token = token
        self.expiration = expiration
    }

    public init(token: String, expiration: Int64) {
        self.init(uid: 0, token: token, expiration: expiration)
    }
}

public protocol CallTokenProvider: AnyObject {
    
    /// Get the App ID of the Agora SDK.
    /// - Returns: The App ID as a string.
    func getAppId() -> String
    
    /// Asynchronously obtains an app-wide RTC credential.
    /// EaseCallUIKit passes `nil` because the returned token is expected to be valid for all channels.
    /// Sign the token for the current IM username as the RTC string user account.
    func getRTCToken(withChannel channelName: String?) async throws -> CallRTCTokenInfo
    
    /// Compatibility entry point. EaseCallUIKit now resolves accounts through the RTC engine.
    func getRelations(rtc uids: [UInt32]) async throws -> [UInt32:String]
}

public extension CallTokenProvider {
    func getRelations(rtc uids: [UInt32]) async throws -> [UInt32: String] { [:] }
}
