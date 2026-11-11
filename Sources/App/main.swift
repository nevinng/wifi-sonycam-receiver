// Copyright (c) 2026 Nevin Ng
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

@main
struct SonyReceiveApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Photo WiFi Receiver") {
            ContentView(model: model)
                .frame(minWidth: 680, minHeight: 560)
        }
        .defaultSize(width: 760, height: 640)
    }
}
