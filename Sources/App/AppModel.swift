// Copyright (c) 2026 Nevin Ng
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import SonyReceiveCore

@MainActor
final class AppModel: ObservableObject {
    @Published var manualIP: String
    @Published var guidText: String
    @Published var destination: URL
    @Published var status = "Ready. Open Send to Computer on the camera."
    @Published var progress = ""
    @Published var log = ""
    @Published var busy = false
    @Published var registering = false
    @Published var networks = ""
    @Published var cameraStatus = "Looking for the camera."
    @Published var cameraSearching = true

    private let defaults = UserDefaults.standard
    private var task: Task<Void, Never>?
    private let cancel = CancelFlag()
    private var monitor: CameraMonitor?
    private var watchGeneration = 0

    init() {
        manualIP = defaults.string(forKey: "cameraIP") ?? ""
        guidText = defaults.string(forKey: "guid") ?? ""
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Sony A7", isDirectory: true)
        if let saved = defaults.string(forKey: "destination") {
            let savedURL = URL(fileURLWithPath: saved)
            let previousDefault = savedURL.lastPathComponent == "Sony A7III"
                && savedURL.deletingLastPathComponent().lastPathComponent == "Pictures"
            destination = previousDefault ? folder : savedURL
            if previousDefault { defaults.set(folder.path, forKey: "destination") }
        } else {
            destination = folder
        }
        refreshNetworks()
        startWatching()
    }

    func refreshNetworks() {
        let found = localIPv4Networks()
        networks = found.isEmpty ? "This Mac is not on an IPv4 network." : found.map(\.ip).joined(separator: ", ")
    }

    func receive() {
        guard !busy else { return }
        busy = true
        progress = ""
        log = ""
        status = "Waiting for the camera."
        defaults.set(manualIP, forKey: "cameraIP")
        defaults.set(guidText, forKey: "guid")
        defaults.set(destination.path, forKey: "destination")
        cancel.reset()
        watchGeneration += 1
        let spotted = monitor?.read().address
        monitor?.stop()
        let typed = manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = typed.isEmpty ? (spotted ?? "") : typed
        cameraSearching = false
        cameraStatus = ip.isEmpty ? "Looking for the camera." : "Connecting to \(ip)."
        let guid = parseGUID(guidText)
        let folder = destination
        task = Task.detached { [cancel] in
            do {
                let result = try CameraSession.receive(
                    manualIP: ip,
                    guidOverride: guid,
                    destination: folder,
                    isCancelled: { cancel.isCancelled },
                    log: { line in Task { @MainActor in self.append(line) } },
                    progress: { line in Task { @MainActor in self.progress = line } }
                )
                await MainActor.run {
                    self.busy = false
                    var summary = "Saved \(result.saved) new photo\(result.saved == 1 ? "" : "s")."
                    if result.skipped > 0 { summary += " \(result.skipped) already in the folder." }
                    if result.moviesLeft > 0 { summary += " Left \(result.moviesLeft) movie\(result.moviesLeft == 1 ? "" : "s") on the card." }
                    self.status = summary
                    self.progress = ""
                    self.startWatching()
                }
            } catch {
                await MainActor.run {
                    self.append(error.localizedDescription)
                    self.busy = false
                    self.progress = ""
                    self.status = error.localizedDescription
                    self.startWatching()
                }
            }
        }
    }

    func registerMac() {
        guard !busy, !registering else { return }
        registering = true
        progress = ""
        log = ""
        status = "Plug the camera in with a USB cable."
        defaults.set(guidText, forKey: "guid")
        cancel.reset()
        let guid = parseGUID(guidText)
        task = Task.detached { [cancel] in
            do {
                try USBRegistration.watch(
                    guidOverride: guid,
                    isCancelled: { cancel.isCancelled },
                    log: { line in Task { @MainActor in self.append(line) } }
                )
                await MainActor.run {
                    self.registering = false
                    self.status = "This Mac is saved on the camera. Unplug USB, open Send to Computer, and press Receive photos."
                }
            } catch {
                await MainActor.run {
                    self.registering = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        cancel.cancel()
        status = "Stopping."
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save here"
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
            defaults.set(url.path, forKey: "destination")
        }
    }

    private func startWatching() {
        monitor?.stop()
        watchGeneration += 1
        let generation = watchGeneration
        let monitor = CameraMonitor()
        self.monitor = monitor
        monitor.start { [weak self] in
            let watch = monitor.read()
            Task { @MainActor in
                guard let self, self.watchGeneration == generation, !self.busy else { return }
                self.cameraStatus = watch.status
                self.cameraSearching = watch.searching
            }
        }
    }

    private func append(_ line: String) {
        log += (log.isEmpty ? "" : "\n") + line
        if log.count > 8000 { log = String(log.suffix(8000)) }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
    func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }
    func reset() {
        lock.lock(); flag = false; lock.unlock()
    }
}
