import Foundation
import ModelKit
import RewriteKit

/// The single definition of when user text needs the user's consent before it leaves
/// (ARCHITECTURE §5.3, §6): the first text to a hosted provider, and a profile's
/// user-authored examples or guidance to a recipient it has not used. A rewrite and Try
/// it (whose samples are user text too, PRODUCT §7) both ask through here.
enum ConsentRule {
    static func notice(for descriptor: ProviderDescriptor, profile: Profile, settings: QuillSettings,
                       remote: Bool, largeText: StartNotice? = nil) -> ConsentNotice? {
        guard remote else { return nil }
        let firstUse = !settings.notifiedProviders.contains(descriptor.id)
        let newRecipient = BuiltInProfiles.hasUserAuthoredText(profile)
            && !(settings.acceptedRecipients[profile.id]?.contains(descriptor.id) ?? false)
        guard firstUse || newRecipient else { return nil }
        return ConsentNotice(provider: descriptor.id, providerName: descriptor.displayName,
                             recipients: recipients(of: descriptor), firstUseOfProvider: firstUse,
                             profileTextToNewRecipient: newRecipient, largeText: largeText)
    }

    /// Records an accepted notice, so it is not asked again.
    static func record(_ notice: ConsentNotice, profileID: UUID, in store: SettingsStore) throws {
        try store.update { settings in
            settings.notifiedProviders.insert(notice.provider)
            if notice.profileTextToNewRecipient {
                settings.acceptedRecipients[profileID, default: []].insert(notice.provider)
            }
        }
    }

    static func recipients(of descriptor: ProviderDescriptor) -> [Recipient] {
        if case .remote(let recipients) = descriptor.traits.execution { return recipients }
        return [.host("localhost")]
    }

    /// Hosted, or a loopback server under `QUILL_TREAT_LOOPBACK_AS_REMOTE`.
    static func isRemote(_ descriptor: ProviderDescriptor, treatLoopbackAsRemote: Bool) -> Bool {
        switch descriptor.traits.execution {
        case .remote: true
        case .onDevice: treatLoopbackAsRemote && descriptor.id.rawValue.hasPrefix(CustomServer.idPrefix)
        }
    }
}
