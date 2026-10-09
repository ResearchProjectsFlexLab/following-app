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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        .defaultSize(width: 720, height: 820)
    }
}
