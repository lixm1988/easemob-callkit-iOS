import Foundation
import UIKit

enum RTCCredentialFailure: LocalizedError {
    case imNotConnected
    case missingIdentity
    case invalidAppID
    case invalidUID
    case invalidCredential
    case staleRequest
    case expired
    case uidChanged
    case tokenNotRenewed

    var errorDescription: String? {
        switch self {
        case .imNotConnected: return "The IM SDK is not connected."
        case .missingIdentity: return "RTC credential identity is unavailable."
        case .invalidAppID: return "RTC App ID is invalid."
        case .invalidUID: return "RTC credential source returned UID 0."
        case .invalidCredential: return "RTC credential source returned an invalid credential."
        case .staleRequest: return "RTC credential request no longer matches the active call."
        case .expired: return "RTC credential has expired."
        case .uidChanged: return "RTC provider returned a different UID while renewing."
        case .tokenNotRenewed: return "RTC provider returned the expired token again."
        }
    }
}

enum RTCCredentialRefreshReason: Equatable {
    case scheduled
    case foreground
    case imConnected
    case join
    case rtcWillExpire
    case rtcExpired

    var forcesRefresh: Bool {
        self == .rtcWillExpire || self == .rtcExpired
    }
}

struct RTCCredentialRequestState {
    let id: UUID
    let appID: String
    let userID: String
    let isStrict: Bool
    let task: Task<RTCCredentialRecord, Error>
}

/// 单个 RTC UID 的解析结果。把错误随结果一起返回，避免用共享状态在并发 Task 之间传错误。
struct RTCRelationResolution {
    let userID: String?
    let error: ChatError?
}

extension CallKitManager {
    @discardableResult
    func hydrateRTCCachesIfNeeded() -> Bool {
        guard let provider = tokenProvider else { return true }
        let resolvedAppID = provider.getAppId()
        guard !resolvedAppID.isEmpty else {
            consoleLogInfo("Cannot hydrate RTC caches because CallTokenProvider App ID is empty.", type: .error)
            return false
        }
        if engine != nil, !appID.isEmpty, appID != resolvedAppID {
            consoleLogInfo("CallTokenProvider App ID changed after the RTC engine was created.", type: .error)
            return false
        }
        appID = resolvedAppID

        let appChanged = $rtcCacheAppID.modify { current -> Bool in
            guard current != resolvedAppID else { return false }
            current = resolvedAppID
            return true
        }
        if appChanged {
            $rtcCredentialCache.modify { $0 = nil }
            $rtcCredentialRequest.modify { state in
                state?.task.cancel()
                state = nil
            }
            $rtcRefreshTask.modify { task in
                task?.cancel()
                task = nil
            }
            $rtcUserIdCache.modify { $0.removeAll() }
            $rtcRelationRequests.modify { requests in
                requests.values.forEach { $0.cancel() }
                requests.removeAll()
            }
            $rtcRelationFailures.modify { $0.removeAll() }
            _ = $loadedRelationAppIDs.modify { $0.remove(resolvedAppID) }
        }

        let shouldLoadRelations = $loadedRelationAppIDs.modify { loaded -> Bool in
            guard !loaded.contains(resolvedAppID) else { return false }
            loaded.insert(resolvedAppID)
            return true
        }
        if shouldLoadRelations {
            let relations = rtcPersistenceStore.loadRelations(appID: resolvedAppID)
            $rtcUserIdCache.modify { $0.merge(relations) { _, new in new } }
        }

        guard let userID = ChatClient.shared().currentUsername, !userID.isEmpty else { return true }
        let key = "\(resolvedAppID)\u{0}\(userID)"
        let identityChanged = $rtcCredentialCache.modify { current -> Bool in
            guard let record = current else { return false }
            guard record.appID != resolvedAppID || record.userID != userID else { return false }
            current = nil
            return true
        }
        if identityChanged {
            _ = $loadedCredentialKeys.modify { $0.remove(key) }
            $rtcCredentialRequest.modify { state in
                state?.task.cancel()
                state = nil
            }
            $rtcRefreshTask.modify { task in
                task?.cancel()
                task = nil
            }
        }
        let shouldLoadCredential = $loadedCredentialKeys.modify { loaded -> Bool in
            guard !loaded.contains(key) else { return false }
            loaded.insert(key)
            return true
        }
        if shouldLoadCredential, let record = rtcPersistenceStore.loadCredential(appID: resolvedAppID, userID: userID) {
            $rtcCredentialCache.modify { current in
                if current == nil || current!.generation <= record.generation { current = record }
            }
            $rtcCredentialGeneration.modify { generation in
                generation = max(generation, record.generation)
            }
            scheduleRTCCredentialRefresh(for: record)
        }
        return true
    }

    func credentialForUse(reason: RTCCredentialRefreshReason) async throws -> RTCCredentialRecord {
        // When RTC token validation is disabled, Agora can assign the UID and no
        // credential request should be made just to obtain a token.
        if config.disableRTCTokenValidation {
            return RTCCredentialRecord(
                appID: appID,
                userID: ChatClient.shared().currentUsername ?? "",
                uid: 0,
                token: "",
                expiration: 0,
                generation: 0
            )
        }
        // CallKit uses an app-wide RTC credential; both sources are requested with a nil channel.
        if tokenProvider == nil {
            guard ChatClient.shared().isConnected else { throw RTCCredentialFailure.imNotConnected }
            let configuredAppID = ChatClient.shared().options.appId ?? ""
            let resolvedAppID = configuredAppID.isEmpty ? appID : configuredAppID
            let currentUserID = ChatClient.shared().currentUsername
            let now = Int64(Date().timeIntervalSince1970)
            if let cached = $rtcCredentialCache.withValue({ $0 }),
               cached.appID == resolvedAppID,
               cached.userID == currentUserID {
                if cached.uid == 0 {
                    return try await credentialFromIMSDK(failedCredential: nil)
                }
                if cached.token.isEmpty && !config.disableRTCTokenValidation {
                    return try await credentialFromIMSDK(failedCredential: cached)
                }
                if cached.expiration == 0 { return cached }
                let remaining = cached.expiration - now
                if remaining > 300 && !reason.forcesRefresh { return cached }
                do {
                    return try await credentialFromIMSDK(failedCredential: cached)
                } catch {
                    if remaining > 0 && reason != .rtcExpired { return cached }
                    throw error
                }
            }
            return try await credentialFromIMSDK(failedCredential: nil)
        }
        guard hydrateRTCCachesIfNeeded() else { throw RTCCredentialFailure.invalidAppID }
        let now = Int64(Date().timeIntervalSince1970)
        if let cached = $rtcCredentialCache.withValue({ $0 }), cached.appID == appID,
           cached.userID == ChatClient.shared().currentUsername {
            if cached.uid == 0 {
                return try await requestRTCCredential(failedCredential: nil)
            }
            if cached.token.isEmpty {
                if config.disableRTCTokenValidation { return cached }
                return try await requestRTCCredential(failedCredential: cached)
            }
            if cached.expiration == 0 { return cached }
            let remaining = cached.expiration - now
            if remaining > 300 && !reason.forcesRefresh { return cached }
            do {
                return try await requestRTCCredential(failedCredential: cached)
            } catch {
                if remaining > 0 && reason != .rtcExpired { return cached }
                throw error
            }
        }
        return try await requestRTCCredential(failedCredential: nil)
    }

    func refreshRTCCredentialIfNeeded(_ reason: RTCCredentialRefreshReason) {
        if tokenProvider == nil, !ChatClient.shared().isConnected {
            consoleLogInfo("Skip IM SDK RTC credential refresh before the IM connection is ready.", type: .info)
            return
        }
        guard let currentUserID = ChatClient.shared().currentUsername, !currentUserID.isEmpty else {
            consoleLogInfo("Cannot request an RTC credential before login.", type: .info)
            return
        }
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let credential = try await self.credentialForUse(reason: reason)
                self.scheduleRTCCredentialRefresh(for: credential)
                if self.hadJoinedChannel && (reason == .scheduled || reason == .foreground) {
                    // 仅在 token 非空时续期，避免 Agora SDK 错误
                    if !credential.token.isEmpty {
                        _ = self.engine?.renewToken(credential.token)
                    }
                }
            } catch {
                consoleLogInfo("RTC credential refresh failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    func requestRTCCredential(failedCredential: RTCCredentialRecord?) async throws -> RTCCredentialRecord {
        guard tokenProvider != nil else { throw RTCCredentialFailure.missingIdentity }
        guard !appID.isEmpty, let userID = ChatClient.shared().currentUsername, !userID.isEmpty else {
            throw RTCCredentialFailure.missingIdentity
        }
        let requestAppID = appID
        let requestUserID = userID
        let isStrict = failedCredential != nil
        let existing = $rtcCredentialRequest.withValue { state -> RTCCredentialRequestState? in
            guard let state = state,
                  state.appID == requestAppID,
                  state.userID == requestUserID else { return nil }
            return !isStrict || state.isStrict ? state : nil
        }
        if let existing = existing { return try await existing.task.value }

        let requestCallID = callInfo?.callId
        let generation = $rtcCredentialGeneration.modify { value -> UInt64 in
            value &+= 1
            return value
        }
        let id = UUID()
        let selected = $rtcCredentialRequest.modify { state -> RTCCredentialRequestState in
            if let state = state,
               state.appID == requestAppID,
               state.userID == requestUserID,
               (!isStrict || state.isStrict) { return state }
            state?.task.cancel()
            let task = Task<RTCCredentialRecord, Error> { [weak self] in
            guard let self = self else { throw CancellationError() }
            let info = try await self.fetchRTCCredential()
            try Task.checkCancellation()
            guard info.uid > 0 else { throw RTCCredentialFailure.invalidUID }
            guard info.expiration >= 0 else { throw RTCCredentialFailure.invalidCredential }
            guard self.config.disableRTCTokenValidation || !info.token.isEmpty else {
                throw RTCCredentialFailure.invalidCredential
            }
            let now = Int64(Date().timeIntervalSince1970)
            guard info.expiration == 0 || info.expiration > now else {
                throw RTCCredentialFailure.invalidCredential
            }
            guard self.appID == requestAppID, ChatClient.shared().currentUsername == requestUserID,
                  self.callInfo?.callId == requestCallID || requestCallID == nil else {
                throw RTCCredentialFailure.staleRequest
            }
            if let failed = failedCredential {
                guard failed.uid == info.uid else { throw RTCCredentialFailure.uidChanged }
                if failed.token == info.token { throw RTCCredentialFailure.tokenNotRenewed }
            }
            let record = RTCCredentialRecord(appID: requestAppID, userID: requestUserID, uid: info.uid, token: info.token, expiration: info.expiration, generation: generation)
            let accepted = self.$rtcCredentialCache.modify { current -> Bool in
                guard current == nil || current!.generation <= generation else { return false }
                current = record
                return true
            }
            guard accepted else { throw RTCCredentialFailure.staleRequest }
            await self.rtcPersistenceStore.saveCredential(record)
            try Task.checkCancellation()
            guard self.appID == requestAppID, ChatClient.shared().currentUsername == requestUserID,
                  self.callInfo?.callId == requestCallID || requestCallID == nil else {
                throw RTCCredentialFailure.staleRequest
            }
            self.scheduleRTCCredentialRefresh(for: record)
            return record
            }
            let newState = RTCCredentialRequestState(id: id, appID: requestAppID, userID: requestUserID, isStrict: isStrict, task: task)
            state = newState
            return newState
        }
        defer {
            $rtcCredentialRequest.modify { state in
                if state?.id == selected.id { state = nil }
            }
        }
        return try await selected.task.value
    }

    private func fetchRTCCredential() async throws -> CallRTCTokenInfo {
        guard let provider = tokenProvider else { throw RTCCredentialFailure.missingIdentity }
        return try await provider.getRTCToken(withChannel: nil)
    }

    private func credentialFromIMSDK(failedCredential: RTCCredentialRecord?) async throws -> RTCCredentialRecord {
        guard tokenProvider == nil else { throw RTCCredentialFailure.staleRequest }
        guard ChatClient.shared().isConnected else { throw RTCCredentialFailure.imNotConnected }
        let configuredAppID = ChatClient.shared().options.appId ?? ""
        let resolvedAppID = configuredAppID.isEmpty ? appID : configuredAppID
        guard !resolvedAppID.isEmpty,
              let userID = ChatClient.shared().currentUsername, !userID.isEmpty else {
            throw RTCCredentialFailure.missingIdentity
        }
        guard engine == nil || appID.isEmpty || appID == resolvedAppID else {
            throw RTCCredentialFailure.invalidAppID
        }
        appID = resolvedAppID
        let isStrict = failedCredential != nil
        let existing = $rtcCredentialRequest.withValue { state -> RTCCredentialRequestState? in
            guard let state = state,
                  state.appID == resolvedAppID,
                  state.userID == userID else { return nil }
            return !isStrict || state.isStrict ? state : nil
        }
        if let existing = existing { return try await existing.task.value }

        let generation = $rtcCredentialGeneration.modify { value -> UInt64 in
            value &+= 1
            return value
        }
        let id = UUID()
        let selected = $rtcCredentialRequest.modify { state -> RTCCredentialRequestState in
            if let state = state,
               state.appID == resolvedAppID,
               state.userID == userID,
               (!isStrict || state.isStrict) { return state }
            state?.task.cancel()
            let task = Task<RTCCredentialRecord, Error> { [weak self] in
                guard let self = self else { throw CancellationError() }
                let info: CallRTCTokenInfo = try await withCheckedThrowingContinuation { continuation in
                    ChatClient.shared().getRTCToken(withChannel: nil) { uid, token, expiration, error in
                        if let error = error {
                            continuation.resume(throwing: NSError(
                                domain: "com.easemob.callkit.rtc-token",
                                code: Int(error.code.rawValue),
                                userInfo: [NSLocalizedDescriptionKey: error.errorDescription ?? "RTC token request failed."]
                            ))
                        } else {
                            continuation.resume(returning: CallRTCTokenInfo(uid: UInt32(uid), token: token ?? "", expiration: Int64(expiration)))
                        }
                    }
                }
                try Task.checkCancellation()
                guard info.uid > 0 else { throw RTCCredentialFailure.invalidUID }
                guard info.expiration >= 0 else { throw RTCCredentialFailure.invalidCredential }
                guard self.config.disableRTCTokenValidation || !info.token.isEmpty else {
                    throw RTCCredentialFailure.invalidCredential
                }
                let now = Int64(Date().timeIntervalSince1970)
                guard info.expiration == 0 || info.expiration > now else {
                    throw RTCCredentialFailure.expired
                }
                guard self.tokenProvider == nil,
                      self.appID == resolvedAppID,
                      ChatClient.shared().currentUsername == userID else {
                    throw RTCCredentialFailure.staleRequest
                }
                if let failed = failedCredential {
                    guard failed.uid == info.uid else { throw RTCCredentialFailure.uidChanged }
                    if !failed.token.isEmpty, failed.token == info.token {
                        throw RTCCredentialFailure.tokenNotRenewed
                    }
                }
                let record = RTCCredentialRecord(appID: resolvedAppID, userID: userID, uid: info.uid, token: info.token, expiration: info.expiration, generation: generation)
                let accepted = self.$rtcCredentialCache.modify { current -> Bool in
                    guard current == nil || current!.generation <= generation else { return false }
                    current = record
                    return true
                }
                guard accepted else { throw RTCCredentialFailure.staleRequest }
                UserDefaults.standard.removeObject(forKey: "CallKitManager.token")
                UserDefaults.standard.removeObject(forKey: "CallKitManager.currentUserRTCUID")
                self.scheduleRTCCredentialRefresh(for: record)
                return record
            }
            let newState = RTCCredentialRequestState(id: id, appID: resolvedAppID, userID: userID, isStrict: isStrict, task: task)
            state = newState
            return newState
        }
        defer {
            $rtcCredentialRequest.modify { state in
                if state?.id == selected.id { state = nil }
            }
        }
        return try await selected.task.value
    }

    func scheduleRTCCredentialRefresh(for record: RTCCredentialRecord) {
        let oldTask = $rtcRefreshTask.modify { current -> Task<Void, Never>? in
            let old = current
            current = nil
            return old
        }
        oldTask?.cancel()
        guard !record.token.isEmpty, record.expiration > 0 else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let fireAt = record.expiration - 300
        let delay: Int64
        if fireAt > now {
            delay = fireAt - now
        } else if record.expiration > now {
            delay = min(60, max(1, (record.expiration - now) / 2))
        } else {
            delay = 0
        }
        let task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            self?.refreshRTCCredentialIfNeeded(.scheduled)
        }
        $rtcRefreshTask.modify { $0 = task }
    }

    func resolveRTCUserIDs(_ uids: [UInt]) async -> (relations: [UInt: String], error: ChatError?) {
        guard hydrateRTCCachesIfNeeded() else { return ([:], nil) }
        let uniqueUIDs = Set(uids)
        var result = $rtcUserIdCache.withValue { cache in
            Dictionary(uniqueKeysWithValues: uniqueUIDs.compactMap { uid in cache[uid].map { (uid, $0) } })
        }
        // 排除近期解析失败过的 uid，避免高频回调下的请求风暴
        let now = Date()
        let suppressed = $rtcRelationFailures.modify { failures -> Set<UInt> in
            failures = failures.filter { now.timeIntervalSince($0.value) < CallKitManager.rtcRelationFailureTTL }
            return Set(failures.keys)
        }
        let missing = uniqueUIDs.filter { $0 > 0 && result[$0] == nil && !suppressed.contains($0) }
        var lastError: ChatError?
        for uid in missing {
            let relationAppID = appID
            let task = $rtcRelationRequests.modify { requests -> Task<RTCRelationResolution, Never> in
                if let existing = requests[uid] { return existing }
                let created = Task<RTCRelationResolution, Never> { [weak self] in
                    guard let self = self else { return RTCRelationResolution(userID: nil, error: nil) }
                    let fetched = await self.fetchRTCRelations([UInt32(uid)])
                    guard !Task.isCancelled, self.appID == relationAppID else {
                        return RTCRelationResolution(userID: nil, error: nil)
                    }
                    guard let userID = fetched.relations[UInt32(uid)], !userID.isEmpty else {
                        return RTCRelationResolution(userID: nil, error: fetched.error)
                    }
                    self.$rtcUserIdCache.modify { $0[uid] = userID }
                    if self.tokenProvider != nil {
                        self.rtcPersistenceStore.scheduleMergeRelations([uid: userID], appID: relationAppID)
                    }
                    return RTCRelationResolution(userID: userID, error: nil)
                }
                requests[uid] = created
                return created
            }
            let resolution = await task.value
            _ = $rtcRelationRequests.modify { $0.removeValue(forKey: uid) }
            if let userID = resolution.userID {
                result[uid] = userID
                _ = $rtcRelationFailures.modify { $0.removeValue(forKey: uid) }
            } else {
                // 记录失败时间戳，TTL 内不再重试该 uid
                $rtcRelationFailures.modify { $0[uid] = Date() }
                if let error = resolution.error { lastError = error }
            }
        }
        return (result, lastError)
    }

    func resolveRTCUserIDs(_ uids: [NSNumber], completion: @escaping ([NSNumber: String]?, ChatError?) -> Void) {
        Task {
            let outcome = await resolveRTCUserIDs(uids.map { $0.uintValue })
            let bridged = Dictionary(uniqueKeysWithValues: outcome.relations.map { (NSNumber(value: $0.key), $0.value) })
            DispatchQueue.main.async {
                completion(bridged, outcome.error)
            }
        }
    }

    private func fetchRTCRelations(_ uids: [UInt32]) async -> (relations: [UInt32: String], error: ChatError?) {
        if let provider = tokenProvider {
            do {
                let values = try await provider.getRelations(rtc: uids)
                return (values.filter { $0.key > 0 && !$0.value.isEmpty }, nil)
            } catch {
                consoleLogInfo("CallTokenProvider failed to resolve RTC UIDs: \(error.localizedDescription)", type: .error)
                return ([:], ChatError(description: error.localizedDescription, code: .general))
            }
        }
        return await withCheckedContinuation { continuation in
            ChatClient.shared().getUserId(byRTCUIds: uids.map { NSNumber(value: $0) }) { relations, error in
                let mapped = Dictionary(uniqueKeysWithValues: (relations ?? [:]).compactMap { key, value in
                    let uid = key.uint32Value
                    return uid > 0 && !value.isEmpty ? (uid, value) : nil
                })
                continuation.resume(returning: (mapped, error))
            }
        }
    }
}
