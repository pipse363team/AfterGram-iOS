import Foundation
import TelegramApi

func afterGramPluginCollectPeers(_ value: Any) -> ([Api.User], [Api.Chat]) {
    var users: [Api.User] = [], chats: [Api.Chat] = []
    func visit(_ value: Any, depth: Int) {
        if depth > 24 || users.count + chats.count >= 10000 { return }
        if let user = value as? Api.User { users.append(user);return }
        if let chat = value as? Api.Chat { chats.append(chat);return }
        if let values = value as? [Any] { for item in values { visit(item, depth: depth + 1) };return }
        if let object = value as? TypeConstructorDescription {
            for (_, field) in object.descriptionFields().1 {
                if let child = field.value { visit(child, depth: depth + 1) }
            }
        }
    }
    visit(value, depth: 0)
    return (users, chats)
}

func afterGramPluginUserSnapshot(_ user: TelegramUser) -> [String: Any] {
    var result: [String: Any] = ["_":"user", "id":user.id.id._internalGetInt64Value(), "self":true, "first_name":user.firstName ?? "", "last_name":user.lastName ?? "", "username":user.username ?? ""]
    if let accessHash = user.accessHash { result["access_hash"] = accessHash.value }
    return result
}
