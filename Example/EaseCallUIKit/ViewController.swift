//
//  ViewController.swift
//  EaseCallUIKit
//
//  Created by zjc19891106 on 06/24/2025.
//  Copyright (c) 2025 zjc19891106. All rights reserved.
//

import UIKit
import EaseCallUIKit
import QuickLook
import AgoraRtcKit

class ViewController: UIViewController {
    
    var callType: CallType = .singleAudio

    @IBOutlet var inputField: UITextField!
    @IBOutlet weak var userIdField: UITextField!
    @IBOutlet weak var passwordField: UITextField!
        
    @IBOutlet var callButton: UIButton!
    @IBOutlet weak var loginButton: UIButton!
    @IBOutlet weak var logoutButton: UIButton!
    @IBOutlet weak var callTypeSegment: UISegmentedControl!
    @IBOutlet weak var logButton: UIButton!
    @IBOutlet weak var tokenProviderButton: UIButton!

    private var isLoggedIn = false

    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        self.callTypeSegment.selectedSegmentIndex = 0
        self.callTypeSegment.selectedSegmentTintColor = .systemBlue
        self.passwordField.isSecureTextEntry = true
        self.setCallControlsEnabled(false)
        self.logoutButton.isEnabled = false
        CallKitManager.shared.profileProvider = self
        CallKitManager.shared.addListener(self)
    }

    /// 跳转到 CallTokenProvider 新用法示例页。
    /// 该页会用你自己的声网 AppId 初始化 CallKit，并由业务服务器提供 RTC Token 与 uid↔userId 映射。
    @IBAction func tokenProviderAction(_ sender: Any) {
//        let controller = TokenProviderViewController()
//        let navigation = UINavigationController(rootViewController: controller)
//        navigation.modalPresentationStyle = .fullScreen
//        present(navigation, animated: true)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }


    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.view.endEditing(true)
    }

    @IBAction func chooseCallType(_ sender: Any) {
        self.callType = CallType(rawValue: UInt(self.callTypeSegment.selectedSegmentIndex)) ?? .singleAudio
    }
    
    @IBAction func loginAction(_ sender: Any) {
        self.view.endEditing(true)
        let username = userIdField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = passwordField.text ?? ""
        guard !username.isEmpty, !password.isEmpty else {
            self.showCallToast(toast: "Please enter user ID and password")
            return
        }
        let ret = ChatClient.shared()
            .perform(NSSelectorFromString("loginWithUsername:password:"), with: username, with: password)?
            .takeUnretainedValue() as? ChatError
        if let error = ret {
            self.showCallToast(toast: "Login failed: \(error.errorDescription ?? "")")
        } else {
            self.showCallToast(toast: "Login successful")
            if !username.isEmpty {
                let profile = CallUserProfile()
                profile.id = username
                profile.avatarURL = "https://xxxxx"
                profile.nickname = "\(username)昵称"
                CallKitManager.shared.currentUserInfo = profile
            }
            self.isLoggedIn = true
            self.setCallControlsEnabled(true)
            self.loginButton.isEnabled = false
            self.logoutButton.isEnabled = true
        }
    }

    @IBAction func logoutAction(_ sender: Any) {
        self.view.endEditing(true)
        let error = ChatClient.shared().logout(false)
        if let error = error {
            self.showCallToast(toast: "Logout failed: \(error.errorDescription ?? "")")
            return
        }
        CallKitManager.shared.cleanUserDefaults()
        CallKitManager.shared.currentUserInfo = nil
        isLoggedIn = false
        setCallControlsEnabled(false)
        loginButton.isEnabled = true
        logoutButton.isEnabled = false
        showCallToast(toast: "Logout successful")
    }
    
    @IBAction func logAction(_ sender: Any) {
        let previewController = QLPreviewController()
        previewController.dataSource = self
        self.present(previewController, animated: true)
    }
    
    @IBAction func callAction(_ sender: Any) {
        self.view.endEditing(true)
        guard isLoggedIn else {
            self.showCallToast(toast: "Please login before starting a call")
            return
        }
        guard let input = inputField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
            self.showCallToast(toast: "Please enter a valid username or group id")
            return
        }
        if self.callType != .groupCall {
            CallKitManager.shared.call(with: input, type: self.callType)
        } else {
            CallKitManager.shared.groupCall(groupId: "325839719825409")
        }
    }

    private func setCallControlsEnabled(_ enabled: Bool) {
        callTypeSegment.isEnabled = enabled
        inputField.isEnabled = enabled
        callButton.isEnabled = enabled
    }
}

extension ViewController: QLPreviewControllerDataSource {
    public func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        1
    }
    
    public func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        let fileURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/HyphenateSDK/easemobLog/easemob.log")
        return fileURL as QLPreviewItem
    }
    
    
}

extension ViewController: CallUserProfileProvider {
    func fetchUserProfiles(profileIds: [String]) async -> [any CallProfileProtocol] {
        return await withTaskGroup(of: [EaseCallUIKit.CallProfileProtocol].self, returning: [EaseCallUIKit.CallProfileProtocol].self) { group in
            var resultProfiles: [EaseCallUIKit.CallProfileProtocol] = []
            group.addTask {
                var resultProfiles: [EaseCallUIKit.CallProfileProtocol] = []
                let result = await self.requestUserInfos(profileIds: profileIds)
                if let infos = result {
                    resultProfiles.append(contentsOf: infos)
                }
                return resultProfiles
            }
            //Await all task were executed.Return values.
            for await result in group {
                resultProfiles.append(contentsOf: result)
            }
            return resultProfiles
        }
    }
    
    func fetchGroupProfiles(profileIds: [String]) async -> [any CallProfileProtocol] {
        return await withTaskGroup(of: [EaseCallUIKit.CallProfileProtocol].self, returning: [EaseCallUIKit.CallProfileProtocol].self) { group in
            var resultProfiles: [EaseCallUIKit.CallProfileProtocol] = []
            group.addTask {
                var resultProfiles: [EaseCallUIKit.CallProfileProtocol] = []
                let result = await self.requestGroupsInfo(groupIds: profileIds)
                if let infos = result {
                    resultProfiles.append(contentsOf: infos)
                }
                return resultProfiles
            }
            //Await all task were executed.Return values.
            for await result in group {
                resultProfiles.append(contentsOf: result)
            }
            return resultProfiles
        }
    }
    
    private func requestUserInfos(profileIds: [String]) async -> [CallProfileProtocol]? {
        var unknownIds = [String]()
        var resultProfiles = [CallProfileProtocol]()
        for profileId in profileIds {
            if let profile = CallKitManager.shared.usersCache[profileId] {
                resultProfiles.append(profile)
            } else {
                unknownIds.append(profileId)
            }
        }
        if unknownIds.isEmpty {
            return resultProfiles
        }
        let result = await ChatClient.shared().userInfoManager?.fetchUserInfo(byId: unknownIds)
        if result?.1 == nil,let infoMap = result?.0 {
            for (userId,info) in infoMap {
                let profile = CallUserProfile()
                let nickname = info.nickname ?? ""
                profile.id = userId
                profile.nickname = nickname
                profile.avatarURL = info.avatarUrl ?? ""

            }
            return resultProfiles
        }
        return []
    }
    
    private func requestGroupsInfo(groupIds: [String]) async -> [CallProfileProtocol]? {
        var resultProfiles = [CallProfileProtocol]()
        let groups = ChatClient.shared().groupManager?.getJoinedGroups() ?? []
        for groupId in groupIds {
            if let group = groups.first(where: { $0.groupId == groupId }) {
                let profile = CallUserProfile()
                profile.id = groupId
                profile.nickname = group.groupName
                profile.avatarURL = group.settings.ext ?? ""
                resultProfiles.append(profile)
            }

        }
        return resultProfiles
    }

    
}

extension ViewController: CallServiceListener {
    func didOccurError(error: CallError) {
        DispatchQueue.main.async {
            self.showCallToast(toast: "Occur error:\(error.errorMessage) on module:\(error.module.rawValue)")
        }
        switch error {
        case .im(.invalidURL):
            print("Invalid URL")
        case .rtc(.invalidToken):
            print("Invalid Token")
        case .business(.state):
            print("State error")
        case .business(.param):
            print("Param error")
        default:
            // 注意这里要通过 error.error.message 访问
            print("Other error: \(error.error.message)")
        }
//        switch error.module {//OC use case
//        case .im:
//            switch error.getIMError() {
//            case .invalidURL:
//                print("")
//            default:
//                break
//            }
//        case .rtc:
//            switch error.getRTCError() {
//            case .invalidToken:
//                print("")
//            default:
//                break
//            }
//        case .business:
//            switch error.getCallBusinessError() {
//            case .state:
//                print("")
//            case .param:
//                print("")
//            case .signaling:
//                print("")
//            default:
//                break
//            }
//        default:
//            break
//        }
    }
        
    func didUpdateCallEndReason(reason: CallEndReason, info: CallInfo) {
        print("didUpdateCallEndReason: \(String(describing: info.inviteMessageId))")
        NotificationCenter.default.post(name: Notification.Name("didUpdateCallEndReason"), object: info.inviteMessageId)
        
    }
    
    func remoteUserDidJoined(userId: String, uid: UInt, channelName: String, type: CallType) {
        
    }
    
    func remoteUserDidLeft(userId: String, uid: UInt, channelName: String, type: CallType) {
        
    }
    
    func onRtcEngineCreated(engine: AgoraRtcEngineKit) {
        
    }
}
