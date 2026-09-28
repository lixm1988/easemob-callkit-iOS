//
//  TokenProviderViewController.swift
//  EaseCallUIKit_Example
//
//  CallTokenProvider 新用法示例页。
//
//  和首页「旧用法」的区别：
//  - 旧用法：`CallKitManager.shared.setup(config)`，登录 IM 后由 IM SDK 下发 RTC AppId / Token。
//  - 新用法：用你自己的 IM AppKey 初始化 IM SDK，再用 `setup(config, tokenProvider:)` 初始化 CallKit。
//    RTC AppId、Token 由 CallTokenProvider 向你们自己的服务端获取，RTC 以当前 IM 账号加入频道。
//
//  推荐在 App 启动时就选定其中一种，不要混用。RTC 引擎创建后不能再切换凭证来源。
//

import UIKit
import EaseCallUIKit
import QuickLook
import AgoraRtcKit

/// CallTokenProvider 示例页：演示用自己的 AppId / 字符串账号 Token 驱动通话。
final class TokenProviderViewController: UIViewController {

    private var callType: CallType = .singleAudio
    private let tokenProvider = ExampleCallTokenProvider()

    private let tipLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.text = "新用法：自己初始化 IM SDK，再用 CallTokenProvider 提供 RTC AppId 和按当前 IM 字符串账号签发的 Token。首页是旧用法，登录后由 IM SDK 下发这些凭证。"
        return label
    }()

    private let callTypeSegment: UISegmentedControl = {
        let control = UISegmentedControl(items: ["audio", "video", "group"])
        control.selectedSegmentIndex = 0
        control.selectedSegmentTintColor = .systemBlue
        return control
    }()

    private let inputField: UITextField = {
        let field = UITextField()
        field.borderStyle = .roundedRect
        field.placeholder = "call user or group with id"
        field.textAlignment = .center
        field.backgroundColor = .systemGray5
        return field
    }()

    private let callButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Call"
        return UIButton(configuration: configuration)
    }()

    private let loginButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Login"
        return UIButton(configuration: configuration)
    }()

    private let logButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Log"
        return UIButton(configuration: configuration)
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "CallTokenProvider"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "关闭",
            style: .plain,
            target: self,
            action: #selector(closeAction)
        )
        setupUI()
        setupCallKitWithTokenProvider()
    }

    /// 新用法的核心初始化。
    ///
    /// 1. IM SDK 仍然用你自己的 AppKey 初始化（本 Example 已在 AppDelegate 完成）。
    /// 2. CallKit 必须走带 `tokenProvider` 的 setup。之后 RTC AppId / Token都不再向 IM SDK 要。
    /// 3. 如果首页已经登录并创建了 RTC 引擎，这里无法再切换凭证来源，需要重启 App 后先进入本页。
    private func setupCallKitWithTokenProvider() {
        guard !agoraAppId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showCallToast(toast: "请先在 PublicDefines.swift 填写 agoraAppId")
            return
        }

        if CallKitManager.shared.engine != nil, CallKitManager.shared.tokenProvider == nil {
            showCallToast(toast: "RTC 引擎已按旧用法创建，无法切换到 CallTokenProvider，请重启 App 后先进入本页")
            return
        }

        let config = CallKitConfig()
        config.enablePIPOn1V1VideoScene = true
        config.disableRTCTokenValidation = true
        // 新用法：把 CallTokenProvider 传给 CallKit。setup 时会立刻用 getAppId() 创建 RTC 引擎。
        CallKitManager.shared.setup(config, tokenProvider: tokenProvider)
        CallKitManager.shared.profileProvider = self
        CallKitManager.shared.addListener(self)
    }

    private func setupUI() {
        [tipLabel, callTypeSegment, inputField, callButton, loginButton, logButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        callTypeSegment.addTarget(self, action: #selector(chooseCallType), for: .valueChanged)
        callButton.addTarget(self, action: #selector(callAction), for: .touchUpInside)
        loginButton.addTarget(self, action: #selector(loginAction), for: .touchUpInside)
        logButton.addTarget(self, action: #selector(logAction), for: .touchUpInside)

        NSLayoutConstraint.activate([
            tipLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            tipLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            tipLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),

            callTypeSegment.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            callTypeSegment.topAnchor.constraint(equalTo: tipLabel.bottomAnchor, constant: 20),
            callTypeSegment.widthAnchor.constraint(equalToConstant: 197),
            callTypeSegment.heightAnchor.constraint(equalToConstant: 32),

            inputField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            inputField.topAnchor.constraint(equalTo: callTypeSegment.bottomAnchor, constant: 20),
            inputField.widthAnchor.constraint(equalToConstant: 225),
            inputField.heightAnchor.constraint(equalToConstant: 40),

            callButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            callButton.topAnchor.constraint(equalTo: inputField.bottomAnchor, constant: 23),
            callButton.heightAnchor.constraint(equalToConstant: 35),

            loginButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loginButton.topAnchor.constraint(equalTo: callButton.bottomAnchor, constant: 16),
            loginButton.heightAnchor.constraint(equalToConstant: 35),

            logButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            logButton.topAnchor.constraint(equalTo: loginButton.bottomAnchor, constant: 16),
            logButton.heightAnchor.constraint(equalToConstant: 35)
        ])
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        view.endEditing(true)
    }

    @objc private func closeAction() {
        dismiss(animated: true)
    }

    @objc private func chooseCallType() {
        callType = CallType(rawValue: UInt(callTypeSegment.selectedSegmentIndex)) ?? .singleAudio
    }

    @objc private func loginAction() {
        view.endEditing(true)
        // IM 登录仍走环信 IM Token。RTC Token 不会在这里获取，而是由 CallTokenProvider 在进房 / 续期时按需回调。
        ChatClient.shared().login(withUsername: userId, token: token) { [weak self] userId, error in
            if let error = error {
                self?.showCallToast(toast: "Login failed: \(error.errorDescription ?? "")")
            } else {
                self?.showCallToast(toast: "Login successful")
                if !userId.isEmpty {
                    let profile = CallUserProfile()
                    profile.id = userId
                    profile.avatarURL = "https://xxxxx"
                    profile.nickname = "\(userId)昵称"
                    CallKitManager.shared.currentUserInfo = profile
                }
                self?.loginButton.isHidden = true
            }
        }
    }

    @objc private func logAction() {
        let previewController = QLPreviewController()
        previewController.dataSource = self
        present(previewController, animated: true)
    }

    @objc private func callAction() {
        view.endEditing(true)
        guard let input = inputField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
            showCallToast(toast: "Please enter a valid username or group id")
            return
        }
        // 呼叫 API 和旧用法相同。差别只在 RTC 凭证从哪里来。
        if callType != .groupCall {
            CallKitManager.shared.call(with: input, type: callType)
        } else {
            CallKitManager.shared.groupCall(groupId: input)
        }
    }
}

// MARK: - ExampleCallTokenProvider

/// 业务侧自己实现的 RTC 凭证提供者。
///
/// CallKit 会在这些时机回调本类，你只需要向自己的服务端拿数据并返回：
/// - `getAppId()`：创建 RTC 引擎时读取，必须是稳定的声网 App ID。
/// - `getRTCToken(withChannel:)`：登录后、进房前、Token 即将过期、回到前台时读取。当前 channel 固定传 `nil`，要求返回应用级 Token。
/// RTC UID 对应的账号由 RTC Engine 查询，无需业务服务器维护映射。
///
/// 返回值约束：
/// - Token 必须按当前 IM username 作为 RTC 字符串账号签发。
/// - expiration 为 Unix 秒；传 0 表示不过期。有效 Token 会在过期前约 5 分钟自动续期。
/// - 除非你把 `CallKitConfig.disableRTCTokenValidation` 设为 true，否则 token 不能为空。
final class ExampleCallTokenProvider: CallTokenProvider {

    /// 返回你自己的声网 App ID。不要返回环信 IM AppKey。
    func getAppId() -> String {
        agoraAppId
    }

    /// 收到 CallKit 的凭证请求后，向自己的服务端换取当前用户字符串账号的 RTC Token / 过期时间。
    ///
    /// - Parameter channelName: 当前实现会传入 `nil`。请签发对所有频道有效的 Token，不要按单个 channel 签发。
    func getRTCToken(withChannel channelName: String?) async throws -> CallRTCTokenInfo {
        // 生产环境必须走你们自己的应用服务器，不要把声网证书写进 App。
        // 本方法演示一次标准请求：把当前 IM userId 发给服务端，换回 token、expiration。
        try await requestRTCTokenFromYourServer(channelName: channelName)
    }

    /// 向自己的服务端请求当前用户的 RTC 凭证。
    ///
    /// 建议服务端返回：
    /// ```
    /// { "token": "007eJx...", "expiration": 1710000000 }
    /// ```
    /// `expiration` 用 Unix 秒；没有过期时间就返回 0。
    private func requestRTCTokenFromYourServer(channelName: String?) async throws -> CallRTCTokenInfo {
        guard let currentUserId = ChatClient.shared().currentUsername, !currentUserId.isEmpty else {
            throw ExampleTokenProviderError.notLogin
        }

        // 如果只是本地验证协议是否接通，可以临时返回下面这组调试值。
        // 真机通话前请改成真实的服务端请求，并删除这段调试返回。
        if !agoraRTCToken.isEmpty {
            return CallRTCTokenInfo(
                token: agoraRTCToken,
                expiration: agoraRTCTokenExpiration
            )
        }

        guard let url = URL(string: "\(tokenProviderBaseURL)/rtc/token") else {
            throw ExampleTokenProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // channelName 当前为 nil，服务端应按应用级 Token 签发。
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "userId": currentUserId,
            "channelName": channelName as Any
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ExampleTokenProviderError.serverFailed
        }

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let token = object?["token"] as? String ?? ""
        let expiration = (object?["expiration"] as? NSNumber)?.int64Value ?? 0
        return CallRTCTokenInfo(token: token, expiration: expiration)
    }


}

private enum ExampleTokenProviderError: LocalizedError {
    case notLogin
    case invalidURL
    case serverFailed

    var errorDescription: String? {
        switch self {
        case .notLogin: return "CallTokenProvider 需要先登录 IM，才能按当前用户换取 RTC Token。"
        case .invalidURL: return "tokenProviderBaseURL 无效，请在 PublicDefines.swift 中填写你们的服务地址。"
        case .serverFailed: return "向业务服务器获取 RTC 凭证失败。"
        }
    }
}

// MARK: - Log / Profile / Listener

extension TokenProviderViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/HyphenateSDK/easemobLog/easemob.log") as QLPreviewItem
    }
}

extension TokenProviderViewController: CallUserProfileProvider {
    func fetchUserProfiles(profileIds: [String]) async -> [any CallProfileProtocol] {
        var resultProfiles: [CallProfileProtocol] = []
        var unknownIds: [String] = []
        for profileId in profileIds {
            if let profile = CallKitManager.shared.usersCache[profileId] {
                resultProfiles.append(profile)
            } else {
                unknownIds.append(profileId)
            }
        }
        guard !unknownIds.isEmpty else { return resultProfiles }
        let result = await ChatClient.shared().userInfoManager?.fetchUserInfo(byId: unknownIds)
        if result?.1 == nil, let infoMap = result?.0 {
            for (userId, info) in infoMap {
                let profile = CallUserProfile()
                profile.id = userId
                profile.nickname = info.nickname ?? ""
                profile.avatarURL = info.avatarUrl ?? ""
                resultProfiles.append(profile)
            }
        }
        return resultProfiles
    }

    func fetchGroupProfiles(profileIds: [String]) async -> [any CallProfileProtocol] {
        let groups = ChatClient.shared().groupManager?.getJoinedGroups() ?? []
        return profileIds.compactMap { groupId in
            guard let group = groups.first(where: { $0.groupId == groupId }) else { return nil }
            let profile = CallUserProfile()
            profile.id = groupId
            profile.nickname = group.groupName
            profile.avatarURL = group.settings.ext
            return profile
        }
    }
}

extension TokenProviderViewController: CallServiceListener {
    func didOccurError(error: CallError) {
        DispatchQueue.main.async {
            self.showCallToast(toast: "Occur error:\(error.errorMessage) on module:\(error.module.rawValue)")
        }
    }

    func didUpdateCallEndReason(reason: CallEndReason, info: CallInfo) {
        print("didUpdateCallEndReason: \(String(describing: info.inviteMessageId))")
    }

    func remoteUserDidJoined(userId: String, uid: UInt, channelName: String, type: CallType) {}

    func remoteUserDidLeft(userId: String, uid: UInt, channelName: String, type: CallType) {}

    func onRtcEngineCreated(engine: AgoraRtcEngineKit) {}
}
