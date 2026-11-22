//
// Copyright © 2026 APK Runner contributors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation
import Network
import UniformTypeIdentifiers

extension UTType {
    /// Android application package, declared in Info.plist (UTImportedTypeDeclarations)
    static let APK = UTType(importedAs: "com.android.package-archive")
}

enum UTMAPKRunnerError: Error {
    case missingAndroidImage
}

extension UTMAPKRunnerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingAndroidImage:
            return NSLocalizedString("This build does not contain the Android image needed to run APK files.", comment: "UTMAPKRunner")
        }
    }
}

/// Runs Android apps (.apk) inside a bundled Android-x86 virtual machine.
///
/// Opening an APK copies it into a queue and starts the Android VM. A service in the
/// guest (apkrunner/android/apkrunner.sh) polls 10.0.2.2:47123, which QEMU's user mode
/// networking forwards to this app's loopback listener. Each connection gets an 8 byte
/// big-endian length followed by the next queued APK (length 0 when nothing is queued).
/// The guest installs the APK and launches it.
@MainActor final class UTMAPKRunner {
    static let shared = UTMAPKRunner()

    nonisolated static let port: UInt16 = 47123

    private static let vmName = "Android (APK Runner)"
    private static let vmIdKey = "APKRunnerVMIdentifier"

    private var listener: NWListener?

    nonisolated private static let queue = DispatchQueue(label: "APK Runner Server")

    /// Queued APKs waiting for the guest to pick them up
    nonisolated static var inboxURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("APK Inbox", isDirectory: true)
    }

    /// Kernel, initrd, disk and command line added to the app bundle by the build
    nonisolated static var bundledImageURL: URL? {
        Bundle.main.url(forResource: "AndroidVM", withExtension: nil)
    }

    nonisolated static func isAPK(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "apk"
    }

    private init() {
    }

    // MARK: - Opening APKs

    /// Queues an APK and makes sure Android is running to install it.
    func open(apk url: URL, data: UTMData) async throws {
        try await Task.detached {
            try Self.enqueue(apk: url)
        }.value
        startServer()
        let vm = try await androidVM(data: data)
        data.listSelect(vm: vm)
        data.run(vm: vm)
    }

    /// Creates the Android VM at first launch so it shows up in the list.
    func prepare(data: UTMData) async {
        startServer()
        guard Self.bundledImageURL != nil else {
            return
        }
        do {
            _ = try await androidVM(data: data)
        } catch {
            logger.error("APK Runner: cannot create Android VM: \(error.localizedDescription)")
        }
    }

    nonisolated private static func enqueue(apk url: URL) throws {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        let stamp = String(format: "%015.0f", Date().timeIntervalSince1970 * 1000)
        let destURL = inboxURL.appendingPathComponent("\(stamp)-\(UUID().uuidString).apk")
        var coordinatorError: NSError?
        var copyError: Error?
        // coordinate so files in iCloud Drive get downloaded first
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinatorError) { readURL in
            do {
                try fileManager.copyItem(at: readURL, to: destURL)
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError {
            throw error
        }
        if let error = copyError {
            throw error
        }
        // "Open in" hands us a copy in Documents/Inbox, which we no longer need
        if url.deletingLastPathComponent().lastPathComponent == "Inbox" {
            try? fileManager.removeItem(at: url)
        }
        logger.info("APK Runner: queued \(url.lastPathComponent)")
    }

    // MARK: - Android VM

    private func androidVM(data: UTMData) async throws -> VMData {
        if let identifier = UserDefaults.standard.string(forKey: Self.vmIdKey),
           let vm = data.virtualMachines.first(where: { $0.id.uuidString == identifier && $0.isLoaded }) {
            return vm
        }
        if let vm = data.virtualMachines.first(where: { $0.isLoaded && !$0.isShortcut && $0.detailsTitleLabel == Self.vmName }) {
            UserDefaults.standard.set(vm.id.uuidString, forKey: Self.vmIdKey)
            return vm
        }
        guard let imageURL = Self.bundledImageURL else {
            throw UTMAPKRunnerError.missingAndroidImage
        }
        let config = try Self.androidConfiguration(imageURL: imageURL)
        let vm = try await data.create(config: config)
        UserDefaults.standard.set(vm.id.uuidString, forKey: Self.vmIdKey)
        return vm
    }

    private static func androidConfiguration(imageURL: URL) throws -> UTMQemuConfiguration {
        let cmdline = try String(contentsOf: imageURL.appendingPathComponent("cmdline.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let target = QEMUTarget_x86_64.q35
        let config = UTMQemuConfiguration()
        config.information.name = vmName
        config.information.iconURL = UTMConfigurationInfo.builtinIcon(named: "android")
        config.information.notes = "Runs Android apps you open with this app. Created by APK Runner."
        config.system.architecture = .x86_64
        config.system.target = target
        config.reset(forArchitecture: .x86_64, target: target)
        // Android x86_64 needs SSSE3/SSE4.2/POPCNT, which the default qemu64 CPU lacks
        config.system.cpu = QEMUCPU_x86_64.Nehalem
        config.system.cpuCount = 2
        config.system.isForceMulticore = true
        config.system.memorySize = 2048
        config.qemu.hasUefiBoot = false
        config.qemu.hasRNGDevice = true
        config.qemu.hasBalloonDevice = false
        config.sound = []
        config.sharing.hasClipboardSharing = false
        config.sharing.directoryShareMode = .none
        if !config.displays.isEmpty {
            config.displays[0].hardware = QEMUDisplayDevice_x86_64.VGA
            config.displays[0].isDynamicResolution = false
        }
        if !config.networks.isEmpty {
            config.networks[0].hardware = QEMUNetworkDevice_x86_64.virtio_net_pci
            config.networks[0].mode = .emulated
            config.networks[0].isIsolateFromHost = false
        }
        var kernel = UTMQemuConfigurationDrive()
        kernel.imageURL = imageURL.appendingPathComponent("vmlinuz")
        kernel.imageType = .linuxKernel
        kernel.isRawImage = true
        var initrd = UTMQemuConfigurationDrive()
        initrd.imageURL = imageURL.appendingPathComponent("initrd.img")
        initrd.imageType = .linuxInitrd
        initrd.isRawImage = true
        var disk = UTMQemuConfigurationDrive()
        disk.imageURL = imageURL.appendingPathComponent("android.qcow2")
        disk.imageType = .disk
        disk.interface = .virtio
        // copy the qcow2 as is instead of converting it
        disk.isRawImage = true
        config.drives = [kernel, initrd, disk]
        // quoted so UTM passes the whole command line as one argument
        config.qemu.additionalArguments = [QEMUArgument("-append"), QEMUArgument("\"\(cmdline)\"")]
        return config
    }

    // MARK: - Server for the guest

    func startServer() {
        guard listener == nil else {
            return
        }
        do {
            listener = try Self.makeListener()
        } catch {
            logger.error("APK Runner: cannot start server: \(error)")
        }
    }

    /// Handlers run on `queue`, so they are set up outside the main actor.
    nonisolated private static func makeListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { connection in
            serve(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.info("APK Runner: listening on port \(port)")
            case .failed(let error):
                logger.error("APK Runner: server failed: \(error)")
                Task { @MainActor in
                    UTMAPKRunner.shared.listener?.cancel()
                    UTMAPKRunner.shared.listener = nil
                }
            default:
                break
            }
        }
        listener.start(queue: queue)
        return listener
    }

    nonisolated private static func nextQueuedAPK() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "apk" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    nonisolated private static func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        var apkURL = nextQueuedAPK()
        var apkData: Data?
        if let url = apkURL {
            do {
                apkData = try Data(contentsOf: url, options: .mappedIfSafe)
            } catch {
                logger.error("APK Runner: cannot read \(url.lastPathComponent): \(error)")
                try? FileManager.default.removeItem(at: url)
                apkURL = nil
            }
        }
        let length = UInt64(apkData?.count ?? 0)
        let header = withUnsafeBytes(of: length.bigEndian) { Data($0) }
        guard let apkURL = apkURL, let apkData = apkData, length > 0 else {
            connection.send(content: header, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        connection.send(content: header, completion: .contentProcessed { error in
            if let error = error {
                logger.error("APK Runner: send failed: \(error)")
                connection.cancel()
                return
            }
            connection.send(content: apkData, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error = error {
                    logger.error("APK Runner: send failed: \(error)")
                } else {
                    logger.info("APK Runner: sent \(apkURL.lastPathComponent) (\(length) bytes)")
                    try? FileManager.default.removeItem(at: apkURL)
                }
                connection.cancel()
            })
        })
    }
}
