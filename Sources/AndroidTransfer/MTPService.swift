import CLibMTP
import Darwin
import Foundation
import TransferCore

struct MTPFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class ProgressHandler {
    let report: (UInt64, UInt64) -> Void
    init(_ report: @escaping (UInt64, UInt64) -> Void) { self.report = report }
}

private let progressCallback: @convention(c) (UInt64, UInt64, UnsafeRawPointer?) -> Int32 = {
    sent, total, context in
    if let context {
        Unmanaged<ProgressHandler>.fromOpaque(context).takeUnretainedValue().report(sent, total)
    }
    return 0
}

struct ConnectedDevice {
    let name: String
    /// Stable identity for on-disk caches; the serial number when the device reports one.
    let cacheIdentity: String
    let storages: [Storage]
}

final class MTPService {
    private let queue = DispatchQueue(label: "AndroidTransfer.MTP")
    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?

    static func applyModificationDate(_ date: Date?, to fileURL: URL) throws {
        guard let date else { return }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
    }

    init() { LIBMTP_Init() }

    deinit {
        if let device { LIBMTP_Release_Device(device) }
    }

    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func connectedDevice() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let device else { throw MTPFailure(message: "No device is connected. Connect your phone and try again.") }
        return device
    }

    private func errorMessage(_ device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, fallback: String) -> String {
        var messages: [String] = []
        var error = LIBMTP_Get_Errorstack(device)
        while let current = error {
            if let text = current.pointee.error_text {
                messages.append(String(cString: text))
            }
            error = current.pointee.next
        }
        LIBMTP_Clear_Errorstack(device)
        return messages.isEmpty ? fallback : "\(fallback)\n\(messages.joined(separator: "\n"))"
    }

    func connect() async throws -> ConnectedDevice {
        try await perform {
            if let device = self.device {
                LIBMTP_Release_Device(device)
                self.device = nil
            }
            var rawDevices: UnsafeMutablePointer<LIBMTP_raw_device_t>?
            var count: Int32 = 0
            let result = LIBMTP_Detect_Raw_Devices(&rawDevices, &count)
            defer { free(rawDevices) }
            guard result == LIBMTP_ERROR_NONE else {
                if result == LIBMTP_ERROR_NO_DEVICE_ATTACHED {
                    throw MTPFailure(message: "No MTP device found. Unlock your phone, connect it with a data-capable USB cable, and select File transfer / MTP in Android's USB settings.")
                }
                throw MTPFailure(message: "USB device detection failed (libmtp error \(result.rawValue)). Disconnect other MTP apps and try again.")
            }
            guard count == 1, let rawDevices else {
                throw MTPFailure(message: count > 1
                    ? "More than one MTP device was found. Disconnect the others and try again."
                    : "No MTP device found. Check the phone's USB mode and connection.")
            }
            guard let device = LIBMTP_Open_Raw_Device_Uncached(rawDevices) else {
                throw MTPFailure(message: "Could not open the device. Unlock it, select File transfer / MTP, and close other apps using it.")
            }
            self.device = device
            do {
                let namePointer = LIBMTP_Get_Modelname(device)
                let name = namePointer.map { String(cString: $0) } ?? "Android device"
                if let namePointer { LIBMTP_FreeMemory(namePointer) }
                let serialPointer = LIBMTP_Get_Serialnumber(device)
                let serial = serialPointer.map { String(cString: $0) } ?? ""
                if let serialPointer { LIBMTP_FreeMemory(serialPointer) }
                let raw = rawDevices.pointee.device_entry
                let identity = serial.isEmpty
                    ? "\(raw.vendor_id):\(raw.product_id):\(name)"
                    : "\(raw.vendor_id):\(raw.product_id):\(serial)"
                LIBMTP_Clear_Errorstack(device)
                guard LIBMTP_Get_Storage(device, 0) == 0 else {
                    throw MTPFailure(message: self.errorMessage(device, fallback: "Could not read device storage."))
                }
                var storages: [Storage] = []
                var pointer = device.pointee.storage
                while let storage = pointer {
                    let name = storage.pointee.StorageDescription.map { String(cString: $0) } ?? "Storage"
                    storages.append(Storage(id: storage.pointee.id, name: name, freeBytes: storage.pointee.FreeSpaceInBytes))
                    pointer = storage.pointee.next
                }
                guard !storages.isEmpty else {
                    throw MTPFailure(message: "No storage is available. Unlock the phone and allow file access, then reconnect.")
                }
                return ConnectedDevice(name: name, cacheIdentity: identity, storages: storages)
            } catch {
                LIBMTP_Release_Device(device)
                self.device = nil
                throw error
            }
        }
    }

    func list(storageID: UInt32, parentID: UInt32) async throws -> [DeviceFile] {
        try await perform {
            let device = try self.connectedDevice()
            LIBMTP_Clear_Errorstack(device)
            var pointer = LIBMTP_Get_Files_And_Folders(device, storageID, parentID)
            if pointer == nil, LIBMTP_Get_Errorstack(device) != nil {
                throw MTPFailure(message: self.errorMessage(device, fallback: "Could not read this folder."))
            }
            var files: [DeviceFile] = []
            while let file = pointer {
                pointer = file.pointee.next
                let name = file.pointee.filename.map { String(cString: $0) } ?? "(Unnamed)"
                files.append(DeviceFile(
                    id: file.pointee.item_id,
                    name: name,
                    size: file.pointee.filesize,
                    isFolder: file.pointee.filetype == LIBMTP_FILETYPE_FOLDER,
                    modifiedAt: MTPDate.date(fromUnixTime: Int(file.pointee.modificationdate))
                ))
                LIBMTP_destroy_file_t(file)
            }
            return FileOrdering.sorted(files)
        }
    }

    func thumbnail(for file: DeviceFile) async throws -> Data? {
        try await perform {
            let device = try self.connectedDevice()
            var bytes: UnsafeMutablePointer<UInt8>?
            var size: UInt32 = 0
            let result = LIBMTP_Get_Thumbnail(device, file.id, &bytes, &size)
            defer { if let bytes { LIBMTP_FreeMemory(bytes) } }
            guard result == 0, let bytes, size > 0 else {
                LIBMTP_Clear_Errorstack(device)
                return nil
            }
            return Data(bytes: bytes, count: Int(size))
        }
    }

    /// Reads the photo's GPS position from its embedded metadata. Only the start of the file is read when the
    /// device supports partial reads; small files whose metadata is not near the start are read in full.
    func photoLocation(for file: DeviceFile) async throws -> PhotoMetadataResult {
        try await perform {
            let device = try self.connectedDevice()
            var result = PhotoMetadataResult.unreadable
            if LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_GetPartialObject) != 0 {
                let length = UInt32(min(file.size, 256 * 1024))
                var bytes: UnsafeMutablePointer<UInt8>?
                var size: UInt32 = 0
                LIBMTP_Clear_Errorstack(device)
                let status = LIBMTP_GetPartialObject(device, file.id, 0, length, &bytes, &size)
                defer { if let bytes { LIBMTP_FreeMemory(bytes) } }
                if status == 0, let bytes, size > 0 {
                    result = PhotoMetadata.location(fromImageData: Data(bytes: bytes, count: Int(size)))
                } else {
                    LIBMTP_Clear_Errorstack(device)
                }
                if UInt64(size) >= file.size { return result == .unreadable ? .noLocation : result }
            }
            guard result == .unreadable, file.size <= 40 * 1024 * 1024 else {
                return result == .unreadable ? .noLocation : result
            }
            return PhotoMetadata.location(fromImageData: try self.readWholeFile(device, file))
        }
    }

    private func readWholeFile(_ device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, _ file: DeviceFile) throws -> Data {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-transfer-metadata-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw MTPFailure(message: "Could not create a temporary file: \(String(cString: strerror(errno)))")
        }
        defer {
            close(descriptor)
            unlink(temporary.path)
        }
        LIBMTP_Clear_Errorstack(device)
        guard LIBMTP_Get_File_To_File_Descriptor(device, file.id, descriptor, nil, nil) == 0 else {
            throw MTPFailure(message: errorMessage(device, fallback: "Could not read \(file.name)."))
        }
        return try Data(contentsOf: temporary)
    }

    /// Copies a file into a temporary file (keeping its extension) so a preview can be generated on the Mac.
    /// With `head`/`tail` set and partial reads supported, only those ranges are copied into a sparse file of
    /// the original size — enough to decode the first frame of a video whose index is at the end of the file.
    /// The caller must delete the returned file.
    func temporaryCopy(of file: DeviceFile, head: UInt64? = nil, tail: UInt64 = 0) async throws -> URL {
        try await perform {
            let device = try self.connectedDevice()
            let ext = (file.name as NSString).pathExtension
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("android-transfer-preview-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw MTPFailure(message: "Could not create a temporary file: \(String(cString: strerror(errno)))")
            }
            var keep = false
            defer {
                close(descriptor)
                if !keep { unlink(url.path) }
            }
            if let head, head + tail < file.size,
               LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_GetPartialObject) != 0 {
                guard ftruncate(descriptor, off_t(file.size)) == 0 else {
                    throw MTPFailure(message: "Could not prepare a temporary file: \(String(cString: strerror(errno)))")
                }
                try self.copyRange(device, file, from: 0, length: head, to: descriptor)
                if tail > 0 { try self.copyRange(device, file, from: file.size - tail, length: tail, to: descriptor) }
            } else {
                LIBMTP_Clear_Errorstack(device)
                guard LIBMTP_Get_File_To_File_Descriptor(device, file.id, descriptor, nil, nil) == 0 else {
                    throw MTPFailure(message: self.errorMessage(device, fallback: "Could not read \(file.name)."))
                }
            }
            keep = true
            return url
        }
    }

    private func copyRange(
        _ device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, _ file: DeviceFile,
        from start: UInt64, length: UInt64, to descriptor: Int32
    ) throws {
        let chunk: UInt64 = 4 * 1024 * 1024
        var offset = start
        let end = start + length
        while offset < end {
            var bytes: UnsafeMutablePointer<UInt8>?
            var size: UInt32 = 0
            LIBMTP_Clear_Errorstack(device)
            let status = LIBMTP_GetPartialObject(device, file.id, offset, UInt32(min(chunk, end - offset)), &bytes, &size)
            defer { if let bytes { LIBMTP_FreeMemory(bytes) } }
            guard status == 0, let bytes, size > 0 else {
                throw MTPFailure(message: errorMessage(device, fallback: "Could not read part of \(file.name)."))
            }
            guard pwrite(descriptor, bytes, Int(size), off_t(offset)) == Int(size) else {
                throw MTPFailure(message: "Could not write a temporary file: \(String(cString: strerror(errno)))")
            }
            offset += UInt64(size)
        }
    }

    func delete(_ file: DeviceFile) async throws {
        try await perform {
            let device = try self.connectedDevice()
            LIBMTP_Clear_Errorstack(device)
            guard LIBMTP_Delete_Object(device, file.id) == 0 else {
                throw MTPFailure(message: self.errorMessage(device, fallback: "Could not delete \(file.name)."))
            }
        }
    }

    func download(_ file: DeviceFile, to destination: URL, progress: @escaping (UInt64, UInt64) -> Void) async throws {
        try await perform {
            let device = try self.connectedDevice()
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".android-transfer-\(UUID().uuidString).part")
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw MTPFailure(message: "Could not create a temporary file: \(String(cString: strerror(errno)))")
            }
            defer {
                close(descriptor)
                if FileManager.default.fileExists(atPath: temporary.path) {
                    do { try FileManager.default.removeItem(at: temporary) }
                    catch { NSLog("Could not remove partial transfer at %@: %@", temporary.path, error.localizedDescription) }
                }
            }
            let handler = ProgressHandler(progress)
            LIBMTP_Clear_Errorstack(device)
            let result = LIBMTP_Get_File_To_File_Descriptor(
                device, file.id, descriptor, progressCallback, Unmanaged.passUnretained(handler).toOpaque()
            )
            withExtendedLifetime(handler) {}
            guard result == 0 else {
                throw MTPFailure(message: self.errorMessage(device, fallback: "Transfer failed. The partial file was not saved."))
            }
            try Self.applyModificationDate(file.modifiedAt, to: temporary)
            guard fsync(descriptor) == 0 else {
                throw MTPFailure(message: "Could not flush the downloaded file: \(String(cString: strerror(errno)))")
            }
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                throw MTPFailure(message: "Could not save the file. Existing files are never overwritten. \(error.localizedDescription)")
            }
        }
    }
}
