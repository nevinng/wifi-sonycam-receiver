// Copyright (c) 2026 Nevin Ng
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            camera
            steps
            form
            status
            log
        }
        .padding(20)
        .onAppear { model.refreshNetworks() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Photo WiFi Receiver")
                .font(.title2.weight(.semibold))
            Text("Copies JPEG and RAW photos from the A7III while it is joined to your Wi-Fi router.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var camera: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Camera").font(.headline)
            HStack(alignment: .top, spacing: 8) {
                if model.cameraSearching {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 2)
                }
                Text(model.cameraStatus)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            let typed = model.manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty {
                Text("Receive photos uses \(typed) and skips the search.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On the camera").font(.headline)
            Text("Menu → Network → Send to Computer, then choose the memory card. Leave the camera on that screen. The camera appears here only while that screen is open. This Mac is on \(model.networks).")
                .fixedSize(horizontal: false, vertical: true)
            Text("The first time, press Set this Mac and plug the camera in with USB. If the port is busy, unplug the cable and plug it in again. Unplug it after the camera accepts this Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Save to")
                    .frame(width: 88, alignment: .leading)
                Text(model.destination.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") { model.chooseFolder() }
                    .disabled(model.busy || model.registering)
            }
            HStack {
                Text("Camera IP")
                    .frame(width: 88, alignment: .leading)
                TextField("Leave empty to search the network", text: $model.manualIP)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.busy || model.registering)
            }
            DisclosureGroup("If the camera refuses this Mac") {
                TextField("Computer identity, 16 bytes as hex", text: $model.guidText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.busy || model.registering)
                Text("Leave this empty. The app uses this Mac’s hardware address. Paste an identity only when you already know the one stored on the camera.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            HStack {
                Button(model.registering ? "Waiting for USB…" : "Set this Mac") { model.registerMac() }
                    .disabled(model.busy || model.registering)
                Spacer()
            }
            .padding(.bottom, 16)
            HStack {
                Button(model.busy ? "Waiting…" : "Receive photos") { model.receive() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.registering)
                if model.busy || model.registering {
                    Button("Stop") { model.stop() }
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(model.destination) }
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.status)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if !model.progress.isEmpty {
                Text(model.progress)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var log: some View {
        ScrollView {
            Text(model.log.isEmpty ? "The log appears here once a transfer starts." : model.log)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(model.log.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
