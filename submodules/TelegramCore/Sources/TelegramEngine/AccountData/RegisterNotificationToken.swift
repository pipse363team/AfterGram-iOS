import Foundation
import SwiftSignalKit
import Postbox
import TelegramApi


public enum NotificationTokenType {
    case aps(encrypt: Bool)
    case voip
    case webPush
}

private func notificationTokenString(_ token: Data, type: NotificationTokenType) -> String {
    if case .webPush = type, let value = String(data: token, encoding: .utf8) {
        return value
    }
    return hexString(token)
}

func _internal_unregisterNotificationToken(account: Account, token: Data, type: NotificationTokenType, otherAccountUserIds: [PeerId.Id]) -> Signal<Never, NoError> {
    let mappedType: Int32
    switch type {
        case .aps:
            mappedType = 1
        case .voip:
            mappedType = 9
        case .webPush:
            mappedType = 10
    }
    return account.network.request(Api.functions.account.unregisterDevice(tokenType: mappedType, token: notificationTokenString(token, type: type), otherUids: otherAccountUserIds.map({ $0._internalGetInt64Value() })))
    |> retryRequest
    |> ignoreValues
}

func _internal_registerNotificationToken(account: Account, token: Data, type: NotificationTokenType, sandbox: Bool, otherAccountUserIds: [PeerId.Id], excludeMutedChats: Bool) -> Signal<Bool, NoError> {
    return accountBackupData(postbox: account.postbox)
    |> mapToSignal { backupData -> Signal<Bool, NoError> in
        guard let backupData else {
            return .single(false)
        }
        let mappedType: Int32
        var keyData = Data()
        switch type {
            case let .aps(encrypt):
                mappedType = 1
                if encrypt {
                    keyData = backupData.notificationEncryptionKey ?? Data()
                }
            case .voip:
                mappedType = 9
                keyData = backupData.notificationEncryptionKey ?? Data()
            case .webPush:
                mappedType = 10
                keyData = backupData.masterDatacenterKey
        }
        var flags: Int32 = 0
        if excludeMutedChats {
            flags |= 1 << 0
        }
        return account.network.request(Api.functions.account.registerDevice(flags: flags, tokenType: mappedType, token: notificationTokenString(token, type: type), appSandbox: sandbox ? .boolTrue : .boolFalse, secret: Buffer(data: keyData), otherUids: otherAccountUserIds.map({ $0._internalGetInt64Value() })))
        |> map { _ -> Bool in
            return true
        }
        |> `catch` { error -> Signal<Bool, NoError> in
            if error.errorDescription == "TOKEN_WAS_INVALIDATED" {
                return .single(false)
            } else {
                return .single(true)
            }
        }
    }
}
