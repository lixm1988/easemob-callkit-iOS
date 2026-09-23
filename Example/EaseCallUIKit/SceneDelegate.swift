//
//  SceneDelegate.swift
//  EaseCallUIKit
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard scene is UIWindowScene else { return }
        // The window and root view controller are created from Main.storyboard
        // through the UISceneStoryboardFile entry in Info.plist.
    }
}
