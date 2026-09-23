//
//  AppDelegate.swift
//  EaseCallUIKit
//
//  Created by zjc19891106 on 06/24/2025.
//  Copyright (c) 2025 zjc19891106. All rights reserved.
//

import UIKit
import EaseCallUIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?


    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        // IM SDK 仍使用自己的 AppKey 初始化；RTC 凭证改由业务侧的 CallTokenProvider 提供。
        let option = ChatSDKOptions(appkey: AppKey)
        option.enableConsoleLog = true
        option.setValue(false, forKey: "enableDnsConfig")
        option.setValue("http://10.202.3.37:8083", forKey: "restServer")
        option.setValue(false, forKey: "enableTLSConnection")
        option.setValue("10.202.3.37", forKey: "chatServer")
        option.setValue(4300, forKey: "chatPort")
        option.setValue("10.202.3.37", forKey: "syncDataWSHost")
        option.setValue(8081, forKey: "syncDataWSPort")
        option.dataSyncType = [.joinedGroups, .conversations, .contacts]
        ChatClient.shared().initializeSDK(with: option)
        let config = CallKitConfig()
        config.enablePIPOn1V1VideoScene = true
        // Example 使用无 RTC Token 校验模式，便于本地联调。
        config.disableRTCTokenValidation = true
        CallKitManager.shared.setup(config, tokenProvider: ExampleCallTokenProvider())
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }


}
