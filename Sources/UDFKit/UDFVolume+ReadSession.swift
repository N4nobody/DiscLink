import Foundation

/// The exact state we successfully synchronized, rather than whatever older VAT
/// a subsequent mount happens to find while searching backwards.
struct CommittedReadState {
    let vatSector: UInt32
    let recordedTail: UInt32
    let entries: [UInt32]
    let header: [UInt8]
    let entry: [UInt8]
}

extension UDFVolume {
    func requireTrustedReadSession() throws {
        if let reason = readSessionFailure { throw UDFError(reason) }
    }

    /// Called only after cached and direct single-sector FE reads both failed.
    /// No writes, transaction rollback, or older-VAT fallback are performed here.
    func recoverReadSession(for address: LBAddr) throws -> FileEntry? {
        try requireTrustedReadSession()
        guard let committed = committedReadState, vatRef != nil, device.isSequential,
              let renewable = device as? RenewableReadSession,
              !transactionInProgress, staged.isEmpty, !cache.hasPendingWrites else { return nil }
        let physical = try sector(address)
        guard !readSessionRecoveryAttempted else {
            throw stopUntrustedReadSession(L("重新打开读取会话后仍无法读取文件条目", "File entries are still unreadable after reopening the read session"))
        }
        readSessionRecoveryAttempted = true
        NSLog("DiscLink read-session recovery begin VAT=%u logical=p%u:%u physical=%u",
              committed.vatSector, UInt32(address.partition), address.block, physical)
        var phase = "acquire"
        var validatedVolume: UDFVolume?
        var validatedEntry: FileEntry?
        do {
            try renewable.renewReadSession {
                // Use a new cache and a fresh mount while the device is read-only.
                // The old volume never adopts a partially validated mapping.
                phase = "mount"
                let fresh = try UDFVolume.open(device)
                phase = "medium-identity"
                guard !mediumDescriptors.isEmpty, fresh.mediumDescriptors == mediumDescriptors,
                      fresh.blockSize == blockSize, fresh.rootICB == rootICB,
                      fresh.fsdAddr == fsdAddr, fresh.vatRef == vatRef, fresh.physRef == physRef else {
                    throw UDFError(L("重新打开后识别到的光盘与原光盘不一致", "The reopened medium does not match the original disc"))
                }
                phase = "committed-vat"
                guard fresh.vatLocation == committed.vatSector,
                      device.lastRecordedSector == committed.recordedTail,
                      fresh.vat == committed.entries, fresh.vatHeader == committed.header else {
                    throw UDFError(L("重新打开后未能确认刚完成写入的最新 VAT", "The reopened session could not confirm the exact VAT from the completed write"))
                }
                phase = "vat-entry"
                let vatEntry = try device.readSectors(committed.vatSector, count: 1)
                guard vatEntry == committed.entry else {
                    throw UDFError(L("最新 VAT 的文件条目与刚写入的内容不一致", "The latest VAT entry does not match the completed write"))
                }
                phase = "root-entry"
                let root = try fresh.loadFileEntry(fresh.rootICB)
                guard root.isDirectory, Tag.parse(root.raw)?.location == root.addr.block else {
                    throw UDFError(L("重新打开后的根目录条目无效", "The reopened root directory entry is invalid"))
                }
                _ = try fresh.readFIDs(root)
                phase = "target-entry"
                let entry = address == fresh.rootICB ? root : try fresh.loadFileEntry(address)
                guard Tag.parse(entry.raw)?.location == address.block else {
                    throw UDFError(L("重新打开后的文件条目位置不一致", "The reopened file entry has an unexpected location"))
                }
                validatedVolume = fresh
                validatedEntry = entry
                phase = "restore-access"
            }
            guard let fresh = validatedVolume, let entry = validatedEntry else {
                throw UDFError(L("光驱没有完成读取会话验证", "The drive did not complete read-session validation"))
            }
            // The mapping is equal by construction; adopt the freshly verified
            // header too, and discard only observations, never pending writes.
            vat = fresh.vat
            vatHeader = fresh.vatHeader
            vatICBSector = fresh.vatICBSector
            cache.discardReadCache()
            NSLog("DiscLink read-session recovery succeeded VAT=%u logical=p%u:%u physical=%u",
                  committed.vatSector, UInt32(address.partition), address.block, physical)
            return entry
        } catch {
            NSLog("DiscLink read-session recovery failed VAT=%u logical=p%u:%u physical=%u phase=%@",
                  committed.vatSector, UInt32(address.partition), address.block, physical, phase)
            throw stopUntrustedReadSession(error.localizedDescription)
        }
    }

    private func stopUntrustedReadSession(_ detail: String) -> UDFError {
        cache.discardReadCache()
        let reason = L("光盘读取会话验证失败，已停止继续写入。请关闭并重新打开光盘，先检查文件，不要重复添加。原因：\(detail)",
                       "Disc read-session validation failed; further writes are disabled. Close and reopen the disc and check its files before adding anything again. Reason: \(detail)")
        readSessionFailure = reason
        return UDFError(reason)
    }
}
