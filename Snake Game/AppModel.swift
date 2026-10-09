//
//  AppModel.swift
//  Snake Game
//
//  Created by Prisha Marpu on 10/2/26.
//

import SwiftUI

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let game = FollowGame()
}
