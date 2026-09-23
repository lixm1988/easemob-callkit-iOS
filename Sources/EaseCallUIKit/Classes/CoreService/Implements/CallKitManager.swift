//
//  CallKitManager.swift
//  EaseCallUIKit
//
//  Created by 朱继超 on 6/24/25.
//

import Foundation
import AgoraRtcKit
import AVKit
import AVFAudio
import PushKit

public let CallKitVersion = "5.0.0"

@objcMembers public class CallKitManager: NSObject {
    /// Cache for user profiles
    @CallAtomicUnfairLock public var usersCache: [String: CallProfileProtocol] = [:]

    /// CallKitManager shared instance
    public static let shared = CallKitManager()
    
    /// Provider for user profiles
    public var profileProvider: CallUserProfileProvider?
    
    /// Provider for user profiles in Objective-C
    public var profileProviderOC: CallUserProfileProviderOC?
    
    /// Provider for call token
    @nonobjc public var tokenProvider: CallTokenProvider?
    
    /// Current call information
    public internal(set) var callInfo : CallInfo? = nil
    
    public internal(set) var receivedCalls = [String:CallInfo]()
        
    /// Cache for call stream views
    public internal(set) var canvasCache: [String: CallStreamView] = [:]
    
    /// Cache for call stream items
    public internal(set) var itemsCache: [String: CallStreamItem] = [:] 
    
    /// Listeners for call events
    public internal(set) var listeners:NSHashTable<CallServiceListener> = NSHashTable<CallServiceListener>.weakObjects()
    
    /// AgoraRtcEngineKit instance
    public private(set) var engine:AgoraRtcEngineKit?
    
    /// Current call view controller
    public internal(set) var callVC: UIViewController?
    
    /// Current user profile information
    public var currentUserInfo: CallProfileProtocol? {
        didSet {
            if let info = currentUserInfo {
                usersCache[ChatClient.shared().currentUsername ?? ""] = info
            }
        }
    }
    
    @nonobjc lazy var rtcPersistenceStore = RTCPersistenceStore()
    @nonobjc @CallAtomicUnfairLock var rtcCredentialCache: RTCCredentialRecord?
    @nonobjc @CallAtomicUnfairLock var rtcUserIdCache: [UInt: String] = [:]
    @nonobjc @CallAtomicUnfairLock var rtcCacheAppID: String = ""
    @nonobjc @CallAtomicUnfairLock var loadedCredentialKeys: Set<String> = []
    @nonobjc @CallAtomicUnfairLock var loadedRelationAppIDs: Set<String> = []
    @nonobjc @CallAtomicUnfairLock var rtcCredentialGeneration: UInt64 = 0
    @nonobjc @CallAtomicUnfairLock var rtcCredentialRequest: RTCCredentialRequestState?
    @nonobjc @CallAtomicUnfairLock var rtcRelationRequests: [UInt: Task<RTCRelationResolution, Never>] = [:]
    /// UID -> IM userId 解析失败的时间戳。用于负缓存，避免帧回调等高频路径对同一个失败 uid 反复发起网络请求。
    @nonobjc @CallAtomicUnfairLock var rtcRelationFailures: [UInt: Date] = [:]
    /// 解析失败后的静默期，静默期内不再对同一个 uid 发起请求。
    @nonobjc static let rtcRelationFailureTTL: TimeInterval = 30
    @nonobjc @CallAtomicUnfairLock var rtcRefreshTask: Task<Void, Never>?
    @nonobjc private var notificationObservers: [NSObjectProtocol] = []

    /// Current user token for AgoraRTC SDK. Runtime access is memory-only.
    public private(set) var token: String {
        get { $rtcCredentialCache.withValue { $0?.token ?? "" } }
        set {
            guard tokenProvider == nil else {
                consoleLogInfo("RTC token is managed by CallTokenProvider and cannot be set directly.", type: .error)
                return
            }
            let identity = (appID, ChatClient.shared().currentUsername ?? "")
            $rtcCredentialCache.modify { current in
                let uid = current?.uid ?? 0
                current = RTCCredentialRecord(appID: identity.0, userID: identity.1, uid: uid, token: newValue, expiration: current?.expiration ?? 0, generation: current?.generation ?? 0)
            }
        }
    }

    /// Current user RTC UID. Runtime access is memory-only.
    public private(set) var currentUserRTCUID: UInt32 {
        get { $rtcCredentialCache.withValue { $0?.uid ?? 0 } }
        set {
            guard tokenProvider == nil else {
                consoleLogInfo("RTC UID is managed by CallTokenProvider and cannot be set directly.", type: .error)
                return
            }
            let identity = (appID, ChatClient.shared().currentUsername ?? "")
            $rtcCredentialCache.modify { current in
                current = RTCCredentialRecord(appID: identity.0, userID: identity.1, uid: newValue, token: current?.token ?? "", expiration: current?.expiration ?? 0, generation: current?.generation ?? 0)
            }
        }
    }
    
    var hadJoinedChannel: Bool = false
    
    /// Last Picture-in-Picture frame
    public internal(set) var lastPIPFrame = CGRect.zero
    
    /// Indicates whether the call is currently in a video exchange state
    public internal(set) var isVideoExchanged = false
    
    /// Popup view for call notifications
    public internal(set) var popup: CallPopupView?
    /// Application ID for Agora SDK
    public var appID: String = ""
    
    /// The throttler for RTC callbacks
    let rtcThrottler = RTCCallbackThrottler()
    
    /// Configuration for CallKitManager
    public private(set) var config: CallKitConfig = CallKitConfig()

    /// Whether compatible with older versions of user information transmission or not.
    public var compatibilityModeForUserInfo = false

    private override init() {
        super.init()
        // Initialize CallKit related services or configurations here
    }
    
    /// Sets up the CallKitManager with an optional token provider.
    @objc public func setup(_ config: CallKitConfig? = nil) {
        ChatClient.shared().removeDelegate(self)
        ChatClient.shared().add(self, delegateQueue: nil)
        ChatClient.shared().callSignalingManager?.remove(self)
        ChatClient.shared().callSignalingManager?.add(self, delegateQueue: .main)
        if let config = config {
            self.config = config
        }
        if let tokenProvider = tokenProvider {
            initializeRTCWithProvider(tokenProvider)
        } else if ChatClient.shared().isConnected {
            initializeRTCFromIMSDKAfterConnection()
        }
        _ = AudioPlayerManager.shared
        consoleLogInfo("CallKitManager setup completed", type: .info)
        if #available(iOS 17.4, *),self.config.enableVOIP {
            LiveCommunicationManager.shared.setupPushKit()
        }
        guard notificationObservers.isEmpty else { return }
        let foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hydrateRTCCachesIfNeeded()
            self?.refreshRTCCredentialIfNeeded(.foreground)
            if let info = self?.callInfo, info.state == .ringing {
                if let controller = UIViewController.currentController {
                    if self?.callInfo?.calleeId == ChatClient.shared().currentUsername {
                        if !(controller is CallMultiViewController || controller is Call1v1AudioViewController || controller is Call1v1VideoViewController) {
                            self?.presentCalleeController(call: info)
                        }
                    }
                }
            }
        }
        let backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.tokenProvider != nil else { return }
            let hasRequest = self.$rtcCredentialRequest.withValue { $0 != nil }
            let taskID = hasRequest ? UIApplication.shared.beginBackgroundTask(withName: "CallKit RTC credential") : .invalid
            Task {
                await self.rtcPersistenceStore.flush()
                if taskID != .invalid {
                    await MainActor.run { UIApplication.shared.endBackgroundTask(taskID) }
                }
            }
        }
        let terminateObserver = NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hangup()
        }
        notificationObservers = [foregroundObserver, backgroundObserver, terminateObserver]
//        return nil
    }

    private func initializeRTCWithProvider(_ tokenProvider: CallTokenProvider) {
        let resolvedAppID = tokenProvider.getAppId()
        guard !resolvedAppID.isEmpty else {
            handleBusinessError(CallError.CallBusiness(error: .param, message: "RTC App ID from CallTokenProvider is empty."))
            return
        }
        guard engine == nil || appID.isEmpty || appID == resolvedAppID else {
            handleBusinessError(CallError.CallBusiness(error: .state, message: "RTC App ID cannot change after the RTC engine is created."))
            return
        }
        appID = resolvedAppID
        if let engineError = setupEngine() {
            handleError(engineError)
            return
        }
        guard hydrateRTCCachesIfNeeded() else {
            handleBusinessError(CallError.CallBusiness(error: .state, message: "Failed to initialize CallTokenProvider RTC caches."))
            return
        }
        if ChatClient.shared().isConnected,
           let currentUserID = ChatClient.shared().currentUsername,
           !currentUserID.isEmpty {
            refreshRTCCredentialIfNeeded(.imConnected)
        }
    }

    private func initializeRTCFromIMSDKAfterConnection() {
        guard tokenProvider == nil, ChatClient.shared().isConnected else {
            handleError(ChatError(description: "RTC initialization failed because CallTokenProvider is configured or IM SDK is not connected.", code: .userNotLogin))
            return
        }
        let resolvedAppID = ChatClient.shared().options.appId ?? ""
        guard !resolvedAppID.isEmpty else {
            handleError(ChatError(description: "App ID is not set.", code: .invalidAppkey))
            return
        }
        guard engine == nil || appID.isEmpty || appID == resolvedAppID else {
            handleBusinessError(CallError.CallBusiness(error: .state, message: "RTC App ID changed after the RTC engine was created."))
            return
        }
        appID = resolvedAppID
        if let engineError = setupEngine() {
            handleError(engineError)
            return
        }
        refreshRTCCredentialIfNeeded(.imConnected)
    }

    /// Sets up CallKit with an async RTC provider.
    @nonobjc public func setup(_ config: CallKitConfig? = nil, tokenProvider: CallTokenProvider) {
        if engine != nil {
            guard self.tokenProvider === tokenProvider, appID == tokenProvider.getAppId() else {
                consoleLogInfo("RTC credential source cannot switch after the RTC engine is created.", type: .error)
                return
            }
        }
        self.tokenProvider = tokenProvider
        setup(config)
    }
    
    @objc func setupEngine() -> ChatError? {
        if self.engine != nil {
            for listener in self.listeners.allObjects {
                if let engine = self.engine {
                    listener.onRtcEngineCreated?(engine: engine)
                }
            }
            return nil
        }
        if self.tokenProvider == nil, !ChatClient.shared().isConnected {
            return ChatError(description: "The IM SDK must be connected before initializing the RTC engine.", code: .userNotLogin)
        }
        if self.appID.isEmpty {
            if self.tokenProvider != nil {
                return ChatError(description: "RTC App ID from CallTokenProvider is empty.", code: .invalidAppkey)
            }
            self.appID = ChatClient.shared().options.appId ?? ""
        }
        if self.appID.isEmpty {
            return ChatError(description: "App ID is not set.", code: .invalidAppkey)
        } else {
            self.engine = AgoraRtcEngineKit.sharedEngine(withAppId: self.appID, delegate: self)
        }
        self.engine?.setParameters("{\"che.audio.mix_with_others\":false}")
        let configuration = AgoraVideoEncoderConfiguration()
        configuration.orientationMode = .fixedPortrait
        configuration.dimensions = CGSize(width: 1280, height: 720)
        configuration.frameRate = 60
        self.engine?.setVideoEncoderConfiguration(configuration)
        
        let cameraConfig = AgoraCameraCapturerConfiguration()
        cameraConfig.cameraDirection = .front
        self.engine?.setCameraCapturerConfiguration(cameraConfig)
        for listener in self.listeners.allObjects {
            if let engine = self.engine {
                listener.onRtcEngineCreated?(engine: engine)
            }
        }
        self.engine?.enableAudio()
        self.engine?.enable(inEarMonitoring: true)
        self.engine?.enableAudioVolumeIndication(618, smooth: 5, reportVad: true)
        self.engine?.setDefaultAudioRouteToSpeakerphone(true)
        self.engine?.setVideoFrameDelegate(self)
        return nil
    }

    /// Checks and requests camera permission.
    public func checkCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        consoleLogInfo("The camera permission is granted.", type: .info)
                    } else {
                        DispatchQueue.main.async {
                            UIViewController.currentController?.showCallToast(toast: "检测到用户拒绝授予摄像头权限，请前往设置开启摄像头权限",duration: 3.0,delay: 0.5)
                        }
                        consoleLogInfo("The camera permission is denied, please enable it in settings.", type: .error)
                    }
                }
            }
        case .authorized:
            consoleLogInfo("The camera permission is authorized.", type: .info)
        case .denied, .restricted:
            // permission denied or restricted
            consoleLogInfo("The camera permission is denied or restricted.", type: .error)
            // 可引导用户去设置中开启：Settings -> 应用名称 -> 摄像头
            DispatchQueue.main.async {
                UIViewController.currentController?.showCallToast(toast: "检测到摄像头权限未开启，请前往设置开启摄像头权限",duration: 3.0,delay: 0.5)
            }
        @unknown default:
            consoleLogInfo("Unknown camera permission status", type: .error)
        }
    }
    
    /// Checks and requests microphone permission.
    public func checkMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .notDetermined:
            // 首次请求权限
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        consoleLogInfo("The microphone permission is granted.", type: .info)
                    } else {
                        DispatchQueue.main.async {
                            UIViewController.currentController?.showCallToast(toast: "检测到用户拒绝授予麦克风权限，请前往设置开启麦克风权限",duration: 3.0,delay: 0.5)
                        }
                        consoleLogInfo("The microphone permission is denied, please enable it in settings.", type: .error)
                    }
                }
            }
        case .authorized:
            consoleLogInfo("The microphone permission is authorized.", type: .info)
        case .denied, .restricted:
            consoleLogInfo("The microphone permission is denied or restricted, please enable it in settings.", type: .error)
            // 引导用户去设置中开启：Settings -> 应用名称 -> 麦克风
            DispatchQueue.main.async {
                UIViewController.currentController?.showCallToast(toast: "检测到麦克风权限未开启，请前往设置开启麦克风权限",duration: 3.0,delay: 0.5)
            }
        @unknown default:
            consoleLogInfo("Unknown microphone permission status", type: .error)
        }
    }
    
    /// Tears down the CallKitManager, releasing resources and stopping the player.Notice that this method should be called when the application is about to terminate or when the CallKitManager is no longer needed.
    @objc public func tearDown() {
        $rtcRefreshTask.modify { task in task?.cancel(); task = nil }
        $rtcCredentialRequest.modify { state in state?.task.cancel(); state = nil }
        $rtcRelationRequests.modify { requests in requests.values.forEach { $0.cancel() }; requests.removeAll() }
        $rtcRelationFailures.modify { $0.removeAll() }
        if tokenProvider != nil { Task { await rtcPersistenceStore.flush() } }
        self.quitCall()
        self.itemsCache.removeAll()
        self.canvasCache.removeAll()
        self.usersCache.removeAll()
        self.listeners.removeAllObjects()
        AgoraRtcEngineKit.destroy()
        self.engine = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            consoleLogInfo("Failed to deactivate audio session: \(error.localizedDescription)", type: .error)
        }
        ChatClient.shared().removeDelegate(self)
        ChatClient.shared().callSignalingManager?.remove(self)
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        $rtcCredentialCache.modify { $0 = nil }
        $rtcUserIdCache.modify { $0.removeAll() }
        $rtcCacheAppID.modify { $0 = "" }
        $loadedCredentialKeys.modify { $0.removeAll() }
        $loadedRelationAppIDs.modify { $0.removeAll() }
        $rtcCredentialGeneration.modify { $0 = 0 }
        self.tokenProvider = nil
        self.appID = ""
        AudioPlayerManager.shared.stopAudio()
    }
    
    /// Quits the current call, stopping any ongoing call and cleaning up resources.
    func ringTimeout() {
        DispatchQueue.main.async {
            AudioPlayerManager.shared.stopAudio()
            if let call = self.callInfo, call.state == .ringing {
                consoleLogInfo("Call ringing timeout, ending call", type: .info)
                self.updateCallEndReason(.noResponse)
            }
        }
    }
    
    /// Updates the call end reason and notifies listeners.
    func cleanUICache() {
        self.itemsCache.removeAll()
        self.canvasCache.removeAll()
    }
    
    /// Updates the call end reason and notifies listeners.
    /// - Parameter vc: The view controller to present the call end reason.
    func showMiniAudioView(vc: UIViewController) {
        self.callVC = vc
        if self.lastPIPFrame == .zero {
            let floating = FloatingAudioView.addToWindow()
            floating?.clickDragViewBlock = { [weak self] in
                guard let `self` = self else { return }
                if let callVC = self.callVC {
                    ($0 as? FloatingAudioView)?.present(on: callVC)
                }
            }
        }
    }
    
    /// Shows the Picture-in-Picture (PIP) view for 1v1 video calls.
    /// - Parameter vc: The view controller to present the PIP view.
    func showPIP(vc: UIViewController) {
        if self.config.enablePIPOn1V1VideoScene {
            if let pipVC = vc as? Call1v1VideoViewController {
                self.callVC = pipVC
            } else {
                consoleLogInfo("PIP is only supported in CallVideoViewController", type: .error)
            }
        } else {
            consoleLogInfo("PIP is not enabled for 1v1 video calls", type: .info)
        }
    }
    
    
    /// When you logout IM SDK, you should call this method to clean up the user defaults.
    @objc public func cleanUserDefaults() {
        let appID = self.appID
        let userID = ChatClient.shared().currentUsername
        let shouldClearPersistence = tokenProvider != nil
        UserDefaults.standard.removeObject(forKey: "CallKitManager.token")
        UserDefaults.standard.removeObject(forKey: "CallKitManager.currentUserRTCUID")
        $rtcCredentialCache.modify { $0 = nil }
        $rtcUserIdCache.modify { $0.removeAll() }
        $rtcCacheAppID.modify { $0 = "" }
        $loadedCredentialKeys.modify { $0.removeAll() }
        $loadedRelationAppIDs.modify { $0.removeAll() }
        $rtcRefreshTask.modify { task in task?.cancel(); task = nil }
        $rtcCredentialRequest.modify { state in state?.task.cancel(); state = nil }
        $rtcRelationRequests.modify { requests in requests.values.forEach { $0.cancel() }; requests.removeAll() }
        $rtcRelationFailures.modify { $0.removeAll() }
        if shouldClearPersistence {
            Task {
                await rtcPersistenceStore.clear(appID: appID.isEmpty ? nil : appID, userID: userID)
                await rtcPersistenceStore.flush()
            }
        }
    }
    
    private func validateItemsCache() {
        let currentUserId = ChatClient.shared().currentUsername ?? ""
        itemsCache = itemsCache.filter { key, item in
            return item.userId == currentUserId ||
            item.uid == self.currentUserRTCUID ||
            key == currentUserId
        }
    }
    
    private func validateCanvasCache() {
        let currentUserId = ChatClient.shared().currentUsername ?? ""
        canvasCache = canvasCache.filter { key, view in
            return key == currentUserId || view.item.uid == self.currentUserRTCUID || view.item.userId == currentUserId
        }
    }
}

extension CallKitManager: ChatClientListener {
    public func connectionStateDidChange(_ aConnectionState: ConnectionState) {
        if aConnectionState == .connected {//IM SDK connected successfully
            if self.tokenProvider == nil {
                self.initializeRTCFromIMSDKAfterConnection()
                return
            }
            guard self.hydrateRTCCachesIfNeeded() else {
                self.handleBusinessError(CallError.CallBusiness(error: .state, message: "Failed to initialize CallTokenProvider RTC caches."))
                return
            }
            let engineError = self.setupEngine()//Set up Agora engine
            if let error = engineError {
                self.handleError(error)
                consoleLogInfo("Failed to setup engine: \(String(describing: error.errorDescription))", type: .error)
                return
            }
            self.refreshRTCCredentialIfNeeded(.imConnected)
        }
    }
    
    public func userDidForbidByServer() {
        self.hangup()
    }
    
    public func userAccountDidRemoveFromServer() {
        self.hangup()
    }
    
    public func userAccountDidForced(toLogout aError: ChatError?) {
        if aError != nil {
            self.hangup()
        }
    }
    
    public func userAccountDidLoginFromOtherDevice(with info: LoginExtensionInfo?) {
        self.hangup()
        self.callVC?.dismiss(animated: true)
    }
    
    func getRTCTokenFromIMSDK(_ refreshRTCToken: Bool = false) {
        guard tokenProvider == nil else {
            consoleLogInfo("Skip IM SDK RTC credential request because CallTokenProvider is configured.", type: .info)
            return
        }
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let record = try await self.credentialForUse(reason: refreshRTCToken ? .rtcWillExpire : .imConnected)
                if refreshRTCToken { _ = self.engine?.renewToken(record.token) }
            } catch {
                consoleLogInfo("Failed to fetch call token: \(error.localizedDescription)", type: .error)
            }
        }
    }
}
