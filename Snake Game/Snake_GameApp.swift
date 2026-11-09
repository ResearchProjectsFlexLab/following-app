//
//  Snake_GameApp.swift
//  Snake Game
//
//  Created by Prisha Marpu on 10/2/26.
//

import SwiftUI

@main
struct Snake_GameApp: App {

    @State private var appModel = AppModel()
    @State private var immersionStyle: any ImmersionStyle = FullImmersionStyle.full

    var body: some Scene {
        WindowGroup(id: AppModel.controlWindowID) {
            ContentView()
                .environment(appModel)
        }
        .defaultSize(width: 620, height: 560)

        ImmersiveSpace(id: AppModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
        }
        .immersionStyle(selection: $immersionStyle, in: .full)
    }
}
