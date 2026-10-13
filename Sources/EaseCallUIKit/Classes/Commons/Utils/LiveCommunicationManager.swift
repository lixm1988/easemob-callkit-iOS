//
//  LiveCommunicationManager.swift
//  EaseCallUIKit
//
//  Created by 朱继超 on 7/29/25.
//

import Foundation
import PushKit
import AVFAudio
#if canImport(LiveCommunicationKit)
import LiveCommunicationKit
#endif

enum LiveCommunicationKitActionType: String {
    case join = "join"
    case end = "end"
    case mute = "mute"
}

@available(iOS 17.4, *)
class LiveCommunicationManager: NSObject {
    // 添加单例
    static let shared = LiveCommunicationManager()
    
    // PushKit相关
    private var pushRegistry: PKPushRegistry?
    
    var manager: ConversationManager?
    
    private var uuid: UUID?
    
    private var handledEndCallId: String?

    private let answerGate = VoIPAnswerGate()
    private var pendingJoinAction: JoinConversationAction?
    private var pendingJoinTimeout: DispatchWorkItem?
    private var pendingJoinStartedAt: TimeInterval?
    private let joinTimeoutSeconds: TimeInterval = 10
    private let backgroundRestorationGate = VoIPBackgroundRestorationGate()
    private var backgroundRestorationTimeout: DispatchWorkItem?
    private var pendingEndAction: EndConversationAction?
    
    var currentUserMute: Bool = false // 当前用户是否静音
    
    // 私有化初始化方法，确保单例
    private override init() {
        super.init()
    }
    
    // MARK: - PushKit Setup
    public func setupPushKit() {
        if !CallKitManager.shared.config.enableVOIP {
            consoleLogInfo("[LiveCommunicationManager] PushKit is not enabled", type: .debug)
            return
        }
        if pushRegistry == nil {
            pushRegistry = PKPushRegistry(queue: DispatchQueue.main)
            pushRegistry?.delegate = self
            pushRegistry?.desiredPushTypes = [.voIP]
        }
    }
    
    func createConversationManager(){
        if manager != nil {
            return
        }
        let config = ConversationManager.Configuration(
            ringtoneName: nil,
            iconTemplateImageData: UIImage(named: "AppIcon")?.pngData(),
            maximumConversationGroups: CallKitManager.shared.config.maximumConversationGroups,
            maximumConversationsPerConversationGroup: CallKitManager.shared.config.maximumConversationsPerConversationGroup,
            includesConversationInRecents: false,
            supportsVideo: true,
            supportedHandleTypes: [.generic]
        )
        manager = ConversationManager(configuration: config)
        manager?.delegate = self
    }
         
    func reportIncomingCall(uuid: UUID, callerName: String, call type: CallType,
                            completion: ((Bool) -> Void)? = nil) {
        let local = Handle(type: .generic, value: callerName, displayName: callerName)
        var capabilities: Conversation.Capabilities? = []
        if type != .singleAudio {
            capabilities = [.video]
        }
        let update = Conversation.Update(localMember: local,members: [local],activeRemoteMembers: [local],capabilities: capabilities)
         
        guard let manager else {
            consoleLogInfo("[LiveCommunicationManager] cannot report incoming call without ConversationManager", type: .error)
            completion?(false)
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            
        }
        Task {
            do {

                try await manager.reportNewIncomingConversation(uuid: uuid, update: update)
                consoleLogInfo("[LiveCommunicationManager] successfully reported new incoming call: \(callerName) uuid: \(uuid.uuidString) type: \(type.rawValue)", type: .debug)
                CallKitManager.shared.callInfo?.state = .ringing
                self.uuid = uuid
                DispatchQueue.main.async {
                    for listener in CallKitManager.shared.listeners.allObjects {
                        listener.onReceivedCall?(callType: type, userId: CallKitManager.shared.callInfo?.callerId ?? "", extensionInfo: CallKitManager.shared.callInfo?.extensionInfo)
                    }
                }
                completion?(true)
            } catch {
                consoleLogInfo("[LiveCommunicationManager] failed to report new incoming call: \(error.localizedDescription)", type: .error)
                completion?(false)
            }
        }
    }
     
    func endCall(){
        let endingCallID = CallKitManager.shared.callInfo?.callId
        DispatchQueue.main.async { [weak self] in
            guard let self, let endingCallID else { return }
            if self.answerGate.pendingCallID == endingCallID {
                self.finishPendingJoin(callID: endingCallID, success: false, endCallOnFailure: false)
            }
            self.answerGate.end(callID: endingCallID)
        }
        if let callId = CallKitManager.shared.callInfo?.callId, !callId.isEmpty {
            self.handledEndCallId = callId
        }
        self.manager?.invalidate()
        self.manager = nil
        self.uuid = nil
        consoleLogInfo("[LiveCommunicationManager] destroy ConversationManager", type: .debug)
    }

    func restoreBackgroundAfterNonRejectCallEnd(callID: String) {
        guard !callID.isEmpty, !backgroundRestorationGate.shouldDefer(callID: callID) else { return }
        let currentCallID = CallKitManager.shared.callInfo?.callId
        guard UIApplication.shared.applicationState == .background,
              currentCallID == nil || currentCallID?.isEmpty == true else { return }
        ChatClient.shared().applicationDidEnterBackground(UIApplication.shared)
    }
}

// MARK: - PKPushRegistryDelegate
@available(iOS 17.4, *)
extension LiveCommunicationManager: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        consoleLogInfo("[LiveCommunicationManager] PushKit token updated", type: .debug)
        ChatClient.shared().bindPushKitToken(pushCredentials.token)
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        consoleLogInfo("[LiveCommunicationManager] didReceiveIncomingPushWith payload: \(payload.dictionaryPayload)", type: .debug)
        ChatClient.shared().applicationWillEnterForeground(UIApplication.shared)
        handleIncomingCall(payload: payload, completion: completion)
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        consoleLogInfo("[LiveCommunicationManager] PushKit token invalidated", type: .debug)
    }
    
    // MARK: - 处理呼叫到来
    private func handleIncomingCall(payload: PKPushPayload, completion: @escaping () -> Void) {
        let custom = payload.dictionaryPayload["e"] as? [String: Any]
        let callExtension: [String: Any]? = {
            if let json = custom?["ext"] as? String,
               let data = json.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return value
            }
            return nil
        }()
        let callId = custom?["callId"] as? String ?? ""
        let callerID = payload.dictionaryPayload["f"] as? String ?? ""
        let calleeID = ChatClient.shared().currentUsername ?? ""
        let callerNickname = custom?["nickname"] as? String ?? ""
        let callerAvatar = custom?["avatar"] as? String ?? ""
        let callType: CallType = (custom?["kind"] as? String)?.uppercased() == "CONFERENCE"
            ? .groupCall : (custom?["mediaType"] as? String)?.uppercased() == "VIDEO" ? .singleVideo : .singleAudio
        let groupId = custom?["conversationId"] as? String ?? ""
        if !callerID.isEmpty, !callerNickname.isEmpty || !callerAvatar.isEmpty {
            let profile = CallKitManager.shared.usersCache[callerID] ?? CallUserProfile()
            profile.id = callerID
            if !callerNickname.isEmpty { profile.nickname = callerNickname }
            if !callerAvatar.isEmpty { profile.avatarURL = callerAvatar }
            CallKitManager.shared.usersCache[callerID] = profile
        }
        self.handledEndCallId = nil
        CallKitManager.shared.callInfo = CallInfo(callId: callId, callerId: callerID, callerDeviceId: "", channelName: callId, type: callType)
        CallKitManager.shared.callInfo?.calleeDeviceId = ChatClient.shared().getDeviceConfig(nil)?.deviceUUID ?? ""
        CallKitManager.shared.callInfo?.groupId = groupId
        CallKitManager.shared.callInfo?.calleeId = calleeID
        CallKitManager.shared.callInfo?.state = .ringing
        CallKitManager.shared.callInfo?.extensionInfo = callExtension
        CallKitManager.shared.hydrateRTCCachesIfNeeded()
        CallKitManager.shared.refreshRTCCredentialIfNeeded(.join)
        if let msgId = payload.dictionaryPayload["m"] as? String {
            CallKitManager.shared.callInfo?.inviteMessageId = msgId
        }

        consoleLogInfo("[LiveCommunicationManager] incoming call:  (\(callerID))", type: .debug)
        LiveCommunicationManager.shared.createConversationManager()
        var uuid = UUID(uuidString: callId)
        if uuid == nil {
            uuid = UUID()
            consoleLogInfo("[LiveCommunicationManager] generated new UUID: \(uuid!.uuidString) callId: \(callId)", type: .debug)
        } else {
            consoleLogInfo("[LiveCommunicationManager] reuse UUID: \(uuid!.uuidString)", type: .debug)
        }
        LiveCommunicationManager.shared.reportIncomingCall(uuid: uuid!, callerName: callerNickname.isEmpty ? callerID:callerNickname,
                                                            call: callType) { reported in
            consoleLogInfo("[LiveCommunicationManager] complete VoIP push after incoming call report: \(reported) callId: \(callId)",
                           type: reported ? .debug : .error)
            completion()
        }
    }
    
    func performAction(type: LiveCommunicationKitActionType) {
        guard let uuid = self.uuid else {
            consoleLogInfo("[LiveCommunicationManager] performAction failed: uuid is nil", type: .error)
            return
        }
        var conversationAction: ConversationAction?
        switch type {
        case .join:
            conversationAction = JoinConversationAction(conversationUUID: uuid)
        case .mute:
            conversationAction = MuteConversationAction(conversationUUID: uuid, isMuted: self.currentUserMute)
        case .end:
            conversationAction = EndConversationAction(conversationUUID: uuid)
        }
        if let action = conversationAction {
            Task {
                do {
                    try await manager?.perform([action])
                    consoleLogInfo("[LiveCommunicationManager] successfully performAction: \(type.rawValue)", type: .debug)
                } catch {
                    consoleLogInfo("[LiveCommunicationManager] failed to performAction: \(error.localizedDescription)", type: .error)
                }
            }
        }
    }
}

@available(iOS 17.4, *)
extension LiveCommunicationManager: ConversationManagerDelegate
{
    func conversationManager(_ manager: ConversationManager, conversationChanged conversation: Conversation) {
        consoleLogInfo("[LiveCommunicationManager] conversationChanged: uuid=\(conversation.uuid.uuidString),state=\(conversation.state),localMember:\(String(describing: conversation.localMember))",type: .debug)
    }
    
    func conversationManagerDidBegin(_ manager: ConversationManager) {
        consoleLogInfo("[LiveCommunicationManager] conversationManagerDidBegin",type: .debug)
    }
    
    func conversationManagerDidReset(_ manager: ConversationManager) {
        consoleLogInfo("[LiveCommunicationManager] conversationManagerDidReset",type: .debug)
    }
    
    func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
        consoleLogInfo("[LiveCommunicationManager] perform action:\(action)",type: .debug)
        switch action.self {
        case let action as LiveCommunicationKit.JoinConversationAction:
            consoleLogInfo("[LiveCommunicationManager] voip.join stage=received uuid=\(action.conversationUUID) mainThread=\(Thread.isMainThread)", type: .debug)
            self.joinAction(action: action)
            break
        case let action as LiveCommunicationKit.EndConversationAction:
            self.endAction(action: action)
            break
        case let action as LiveCommunicationKit.MuteConversationAction:
            self.muteAction(action: action)
            break
        default:
            break
        }
    }
    
    private func joinAction(action: JoinConversationAction) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.joinAction(action: action) }
            return
        }
        guard let call = CallKitManager.shared.callInfo, !call.callId.isEmpty,
              action.conversationUUID == uuid else {
            consoleLogInfo("[LiveCommunicationManager] voip.join stage=fail reason=call_mismatch uuid=\(action.conversationUUID) currentCallId=\(CallKitManager.shared.callInfo?.callId ?? "")", type: .error)
            action.fail()
            return
        }
        consoleLogInfo("[LiveCommunicationManager] voip.join stage=main callId=\(call.callId) state=\(call.state) remainingMs=\(Int(action.timeoutDate.timeIntervalSinceNow * 1000))", type: .debug)
        if answerGate.isFulfilled(callID: call.callId), call.state != .idle {
            consoleLogInfo("[LiveCommunicationManager] voip.join stage=fulfill_before reason=already_fulfilled callId=\(call.callId)", type: .debug)
            action.fulfill()
            consoleLogInfo("[LiveCommunicationManager] voip.join stage=fulfill_after reason=already_fulfilled callId=\(call.callId)", type: .debug)
            return
        }
        guard call.state == .ringing, pendingJoinAction == nil else {
            consoleLogInfo("[LiveCommunicationManager] voip.join stage=fail reason=call_unavailable callId=\(call.callId) pending=\(pendingJoinAction != nil)", type: .error)
            action.fail()
            return
        }
        if let currentVC = UIViewController.currentController,
           !(currentVC is Call1v1AudioViewController || currentVC is Call1v1VideoViewController || currentVC is CallMultiViewController) {
            currentVC.showCallToast(toast: "Connecting".call.localize)
        }
        answerGate.begin(callID: call.callId)
        pendingJoinAction = action
        pendingJoinStartedAt = ProcessInfo.processInfo.systemUptime
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.answerGate.pendingCallID == call.callId else { return }
            consoleLogInfo("[LiveCommunicationManager] joining call timed out: \(call.callId)", type: .error)
            self.finishPendingJoin(callID: call.callId, success: false)
        }
        pendingJoinTimeout = timeout
        let remainingActionTime = max(0, action.timeoutDate.timeIntervalSinceNow - 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + min(joinTimeoutSeconds, remainingActionTime), execute: timeout)
        if !ChatClient.shared().isConnected {
            consoleLogInfo("[LiveCommunicationManager] reconnect IM for join action, callId: \(call.callId)", type: .debug)
            ChatClient.shared().applicationWillEnterForeground(UIApplication.shared)
        }
        resumePendingJoinIfReady()
    }

    func signalingInvitationReceived(callID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.answerGate.invitationReceived(callID: callID)
            self?.resumePendingJoinIfReady()
        }
    }

    func imDidConnect() {
        DispatchQueue.main.async { [weak self] in self?.resumePendingJoinIfReady() }
    }

    private func resumePendingJoinIfReady() {
        guard let callID = answerGate.pendingCallID else { return }
        let call = CallKitManager.shared.callInfo
        let isConnected = ChatClient.shared().isConnected
        let hasEngine = CallKitManager.shared.engine != nil
        let isRinging = call?.callId == callID && call?.state == .ringing
        guard hasEngine, answerGate.beginAcceptIfReady(callID: callID,
                                                       isConnected: isConnected,
                                                       isRinging: isRinging) else {
            consoleLogInfo("[LiveCommunicationManager] join waiting callId: \(callID) connected: \(isConnected) engine: \(hasEngine) ringing: \(isRinging)", type: .debug)
            return
        }
        Task { [weak self] in
            do {
                _ = try await CallKitManager.shared.credentialForUse(reason: .join)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.answerGate.pendingCallID == callID else { return }
                    guard ChatClient.shared().isConnected,
                          CallKitManager.shared.callInfo?.callId == callID,
                          CallKitManager.shared.callInfo?.state == .ringing else {
                        self.finishPendingJoin(callID: callID, success: false)
                        return
                    }
                    CallKitManager.shared.acceptForVoIP { [weak self] success in
                        consoleLogInfo("[LiveCommunicationManager] voip.join stage=accept_callback callId=\(callID) success=\(success) mainThread=\(Thread.isMainThread)", type: .debug)
                        DispatchQueue.main.async { [weak self] in
                            self?.finishPendingJoin(callID: callID, success: success)
                        }
                    }
                }
            } catch {
                consoleLogInfo("[LiveCommunicationManager] RTC credential unavailable: \(error.localizedDescription)", type: .error)
                DispatchQueue.main.async { [weak self] in
                    self?.finishPendingJoin(callID: callID, success: false)
                }
            }
        }
    }

    private func finishPendingJoin(callID: String, success: Bool, endCallOnFailure: Bool = true) {
        guard answerGate.pendingCallID == callID, let action = pendingJoinAction else { return }
        let callIsCurrent = CallKitManager.shared.callInfo?.callId == callID
            && CallKitManager.shared.callInfo?.state != .idle
        let didAccept = success && callIsCurrent
        let elapsedMs = pendingJoinStartedAt.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) } ?? -1
        pendingJoinAction = nil
        pendingJoinStartedAt = nil
        pendingJoinTimeout?.cancel()
        pendingJoinTimeout = nil
        answerGate.end(callID: callID)
        if didAccept {
            answerGate.markFulfilled(callID: callID)
            consoleLogInfo("[LiveCommunicationManager] voip.join stage=fulfill_before callId=\(callID) elapsedMs=\(elapsedMs)", type: .debug)
            action.fulfill()
            consoleLogInfo("[LiveCommunicationManager] voip.join stage=fulfill_after callId=\(callID) elapsedMs=\(elapsedMs)", type: .debug)
        } else {
            consoleLogInfo("[LiveCommunicationManager] voip.join stage=fail_before callId=\(callID) elapsedMs=\(elapsedMs) success=\(success) callIsCurrent=\(callIsCurrent)", type: .error)
            action.fail()
            consoleLogInfo("[LiveCommunicationManager] voip.join stage=fail_after callId=\(callID)", type: .debug)
            if endCallOnFailure, callIsCurrent {
                CallKitManager.shared.updateCallEndReason(.abnormalEnd)
            }
        }
    }
    
    private func muteAction(action: MuteConversationAction) {
        // 静音操作
        if let call = CallKitManager.shared.callInfo {
            if call.state == .answering {
                if UIApplication.shared.applicationState == .background || UIApplication.shared.applicationState == .inactive {
                    CallKitManager.shared.enableLocalAudio(!action.isMuted)
                }
                action.fulfill()
            } else {
                consoleLogInfo("[LiveCommunicationManager] call is not answering", type: .error)
                action.fail()
            }
        } else {
            consoleLogInfo("[LiveCommunicationManager] do not have call info", type: .error)
            action.fail()
        }
    }
    
    private func hangupCurrentCallIfNeeded(source: String, rejectionCompletion: ((Bool) -> Void)? = nil) -> Bool {
        guard let call = CallKitManager.shared.callInfo, !call.callId.isEmpty else {
            consoleLogInfo("[LiveCommunicationManager] skip \(source) because call info is empty", type: .debug)
            return false
        }
        if handledEndCallId == call.callId {
            consoleLogInfo("[LiveCommunicationManager] skip duplicate \(source) for callId: \(call.callId)", type: .debug)
            return false
        }
        handledEndCallId = call.callId
        if let rejectionCompletion, call.state == .ringing {
            CallKitManager.shared.hangupForVoIPRejection(completion: rejectionCompletion)
        } else {
            CallKitManager.shared.hangup()
        }
        return true
    }

    private func finishBackgroundRestoration(callID: String, source: String) {
        guard backgroundRestorationGate.shouldDefer(callID: callID) else { return }
        backgroundRestorationTimeout?.cancel()
        backgroundRestorationTimeout = nil
        let action = pendingEndAction
        pendingEndAction = nil
        CallKitManager.shared.finishVoIPRejectionIfNeeded(callID: callID)
        let currentCallID = CallKitManager.shared.callInfo?.callId
        let shouldRestore = backgroundRestorationGate.finish(callID: callID,
            currentCallID: currentCallID, isBackground: UIApplication.shared.applicationState == .background)
        if shouldRestore {
            consoleLogInfo("[LiveCommunicationManager] restore background after reject \(source), callId: \(callID)", type: .debug)
            ChatClient.shared().applicationDidEnterBackground(UIApplication.shared)
        }
        action?.fulfill()
    }
    
    private func endAction(action: EndConversationAction) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.endAction(action: action) }
            return
        }
        consoleLogInfo("[LiveCommunicationManager] perform endAction:",type: .debug)
        if let callID = answerGate.pendingCallID {
            finishPendingJoin(callID: callID, success: false, endCallOnFailure: false)
        }
        let rejectingCallID: String? = {
            guard let call = CallKitManager.shared.callInfo, !call.callId.isEmpty,
                  call.state == .ringing, handledEndCallId != call.callId else { return nil }
            return call.callId
        }()
        if let rejectingCallID {
            backgroundRestorationGate.begin(callID: rejectingCallID)
            pendingEndAction = action
        }
        let didHangup = hangupCurrentCallIfNeeded(source: "endAction", rejectionCompletion: rejectingCallID.map { callID in
            { [weak self] success in
                consoleLogInfo("[LiveCommunicationManager] reject completion: \(success), callId: \(callID)", type: .debug)
                self?.finishBackgroundRestoration(callID: callID, source: success ? "ack" : "failure")
            }
        })
        if let rejectingCallID {
            guard didHangup else {
                finishBackgroundRestoration(callID: rejectingCallID, source: "skipped")
                return
            }
            let timeout = DispatchWorkItem { [weak self] in
                self?.finishBackgroundRestoration(callID: rejectingCallID, source: "timeout")
            }
            backgroundRestorationTimeout = timeout
            let remainingActionTime = max(0, action.timeoutDate.timeIntervalSinceNow - 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + min(5, remainingActionTime), execute: timeout)
        } else {
            action.fulfill()
        }
    }
    
    func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.conversationManager(manager, timedOutPerforming: action) }
            return
        }
        // 会话超时
        consoleLogInfo("[LiveCommunicationManager] perform timedOutPerforming:\(action)",type: .debug)
        if let callID = answerGate.pendingCallID {
            finishPendingJoin(callID: callID, success: false, endCallOnFailure: false)
        }
        _ = hangupCurrentCallIfNeeded(source: "timedOutPerforming")
    }
    
    func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession) {
        consoleLogInfo("[LiveCommunicationManager] voip.audioSession stage=didActivate callId=\(CallKitManager.shared.callInfo?.callId ?? "") pendingCallId=\(answerGate.pendingCallID ?? "") category=\(audioSession.category.rawValue) mode=\(audioSession.mode.rawValue) inputs=\(audioSession.currentRoute.inputs.map { $0.portType.rawValue }) mainThread=\(Thread.isMainThread)", type: .debug)
    }
    
    func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.conversationManager(manager, didDeactivate: audioSession) }
            return
        }
        consoleLogInfo("[LiveCommunicationManager] voip.audioSession stage=didDeactivate callId=\(CallKitManager.shared.callInfo?.callId ?? "") pendingCallId=\(answerGate.pendingCallID ?? "") mainThread=\(Thread.isMainThread)", type: .debug)
        if let callID = answerGate.pendingCallID {
            finishPendingJoin(callID: callID, success: false, endCallOnFailure: false)
        }
        _ = hangupCurrentCallIfNeeded(source: "didDeactivate")
    }
}
