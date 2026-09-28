//
//  PublicDefines.swift
//  EaseCallUIKit_Example
//
//  Created by 朱继超 on 8/14/25.
//  Copyright © 2025 CocoaPods. All rights reserved.
//

import Foundation

/// https://docs-im-beta.easemob.com/product/enable_and_configure_IM.html#%E8%8E%B7%E5%8F%96%E7%8E%AF%E4%BF%A1%E5%8D%B3%E6%97%B6%E9%80%9A%E8%AE%AF-im-%E7%9A%84%E4%BF%A1%E6%81%AF
let AppKey: String = "easemob#dutest01"

let userId: String = "du003"

let token: String = "1"

// MARK: - CallTokenProvider 新用法配置
// 首页旧用法不需要填下面这些。只有进入 TokenProvider 示例页时才用到。
// 生产环境请把 字符串账号的 RTC Token放到你们自己的应用服务器，不要把证书写进客户端。

/// 你自己的声网 App ID。CallTokenProvider.getAppId() 会原样返回它，用来创建 RTC 引擎。
let agoraAppId: String = "your-agora-app-id"

/// 你们自己签发 RTC Token 的服务地址。示例页会请求 `{base}/rtc/token`，按 currentUsername 字符串账号签发。
let tokenProviderBaseURL: String = "https://your-server.com"

/// 本地调试用。填了字符串账号的 token 时，示例页会跳过网络请求，直接把这组值交给 CallKit。
let agoraRTCToken: String = ""
/// Token 过期时间，Unix 秒。0 表示不过期。正式环境请用服务端返回的真实过期时间。
let agoraRTCTokenExpiration: Int64 = 0



