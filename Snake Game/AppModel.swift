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
    static let controlWindowID = "control"
    static let immersiveSpaceID = "tracking-space"

    let session = SessionController()
    var immersiveSpaceIsOpen = false
    var controlWindowIsOpen = false
    /// Set while Start waits for the immersive space; the space begins the session when it appears.
    var isOpeningSpace = false

    var game: FollowGame { session.game }
}
