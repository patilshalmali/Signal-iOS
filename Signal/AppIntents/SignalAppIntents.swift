//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AppIntents
import Foundation
import UIKit

import SignalServiceKit

@available(iOS 16.0, *)
enum SignalIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case notRegistered
    case appNotReady
    case conversationNotFound
    case conversationCannotReceiveMessages
    case emptyMessage
    case sendFailed
    case sendTimedOut

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRegistered:
            return "Signal is not set up or signed in. Please open Signal and register your account first."
        case .appNotReady:
            return "Signal must be open and unlocked before you can use this shortcut."
        case .conversationNotFound:
            return "The selected Signal conversation could not be found."
        case .conversationCannotReceiveMessages:
            return "The selected Signal conversation cannot receive messages."
        case .emptyMessage:
            return "The message text cannot be empty."
        case .sendFailed:
            return "Signal could not send the message."
        case .sendTimedOut:
            return "Signal has not confirmed the message yet. It may still send; check the chat before trying again."
        }
    }
}

@available(iOS 16.0, *)
private func waitForSignalEnvironment(timeoutSeconds: Double = 3.5) async -> Bool {
    guard !Task.isCancelled else { return false }

    if AppReadinessObjcBridge.isAppReady, SSKEnvironment.hasShared {
        return true
    }

    let interval: UInt64 = 150_000_000
    let iterations = Int((timeoutSeconds * 1_000_000_000) / Double(interval))
    for _ in 0..<iterations {
        try? await Task.sleep(nanoseconds: interval)
        guard !Task.isCancelled else { return false }
        if AppReadinessObjcBridge.isAppReady, SSKEnvironment.hasShared {
            return true
        }
    }
    return AppReadinessObjcBridge.isAppReady && SSKEnvironment.hasShared
}

@available(iOS 16.0, *)
@MainActor
private func ensureSignalReadyAndUnlocked() async throws {
    guard await waitForSignalEnvironment() else {
        throw SignalIntentError.appNotReady
    }

    guard DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
        throw SignalIntentError.notRegistered
    }

    if SignalApp.shared.conversationSplitViewController == nil {
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if SignalApp.shared.conversationSplitViewController != nil { break }
        }
    }

    guard
        CurrentAppContext().isMainAppAndActiveIsolated,
        SignalApp.shared.conversationSplitViewController != nil
    else {
        throw SignalIntentError.appNotReady
    }

    try await AppEnvironment.shared.screenLockUI.waitForScreenUnlockThrowingPrevious()
}

@available(iOS 16.0, *)
@MainActor
private func prepareUIForIntentPresentation() async throws {
    guard let window = CurrentAppContext().mainWindow, window.rootViewController != nil else {
        throw SignalIntentError.appNotReady
    }

    AppEnvironment.shared.windowManagerRef.minimizeCallIfNeeded()

    await withCheckedContinuation { continuation in
        SignalApp.shared.dismissAllModals(animated: false) {
            continuation.resume()
        }
    }
}

@available(iOS 16.0, *)
private func canExposeConversationEntities() async -> Bool {
    guard
        await waitForSignalEnvironment(),
        DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered
    else {
        return false
    }

    return await MainActor.run {
        UIApplication.shared.isProtectedDataAvailable
            && !AppEnvironment.shared.screenLockUI.isLockedForAppIntents
    }
}

@available(iOS 16.0, *)
private func canResolveSavedConversationEntity(timeoutSeconds: Double = 3.5) async -> Bool {
    guard
        await waitForSignalEnvironment(timeoutSeconds: timeoutSeconds),
        DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered
    else {
        return false
    }

    return await MainActor.run {
        UIApplication.shared.isProtectedDataAvailable
    }
}

@available(iOS 16.0, *)
struct SignalConversationEntity: AppEntity {
    static var defaultQuery = SignalConversationQuery()
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Signal Conversation"

    var id: String
    var name: String
    var isGroup: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: isGroup
                ? LocalizedStringResource("Group Chat", comment: "Subtitle for group chat entity")
                : LocalizedStringResource("Contact", comment: "Subtitle for contact entity"),
            image: .init(systemName: isGroup ? "person.3.fill" : "person.crop.circle.fill"),
        )
    }
}

@available(iOS 16.0, *)
struct SignalConversationQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SignalConversationEntity] {
        guard await canResolveSavedConversationEntity() else { return [] }

        return SSKEnvironment.shared.databaseStorageRef.read { tx in
            identifiers.compactMap { uniqueId in
                guard let thread = DependenciesBridge.shared.threadStore.fetchThread(uniqueId: uniqueId, tx: tx) else {
                    return nil
                }
                guard thread.shouldThreadBeVisible else { return nil }
                let name = SSKEnvironment.shared.contactManagerRef.displayName(for: thread, tx: tx)?.resolvedValue() ?? "Signal Contact"
                return SignalConversationEntity(id: uniqueId, name: name, isGroup: thread is TSGroupThread)
            }
        }
    }

    func suggestedEntities() async throws -> [SignalConversationEntity] {
        guard await canExposeConversationEntities() else { return [] }

        return SSKEnvironment.shared.databaseStorageRef.read { tx in
            var list = [SignalConversationEntity]()
            DependenciesBridge.shared.threadStore.enumerateNonStoryThreads(tx: tx) { thread in
                guard thread.shouldThreadBeVisible else { return true }
                let name = SSKEnvironment.shared.contactManagerRef.displayName(for: thread, tx: tx)?.resolvedValue() ?? "Signal Contact"
                list.append(SignalConversationEntity(id: thread.uniqueId, name: name, isGroup: thread is TSGroupThread))
                return list.count < 30
            }
            return list
        }
    }

    func entities(matching string: String) async throws -> [SignalConversationEntity] {
        guard await canExposeConversationEntities() else { return [] }

        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return try await suggestedEntities()
        }

        return SSKEnvironment.shared.databaseStorageRef.read { tx in
            var list = [SignalConversationEntity]()
            DependenciesBridge.shared.threadStore.enumerateNonStoryThreads(tx: tx) { thread in
                guard thread.shouldThreadBeVisible else { return true }
                let name = SSKEnvironment.shared.contactManagerRef.displayName(for: thread, tx: tx)?.resolvedValue() ?? ""
                guard name.localizedCaseInsensitiveContains(query) else { return true }
                list.append(SignalConversationEntity(id: thread.uniqueId, name: name, isGroup: thread is TSGroupThread))
                return list.count < 25
            }
            return list
        }
    }
}

@available(iOS 16.0, *)
struct SendSignalMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Signal Message"
    static var description = IntentDescription("Sends a text message after device authentication.")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$message) to \(\.$recipient)")
    }

    @Parameter(title: "Recipient", requestValueDialog: IntentDialog("Who would you like to message on Signal?"))
    var recipient: SignalConversationEntity

    @Parameter(title: "Message", requestValueDialog: IntentDialog("What would you like to say?"))
    var message: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmedText = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw SignalIntentError.emptyMessage
        }
        guard await canResolveSavedConversationEntity(timeoutSeconds: 25) else {
            throw SignalIntentError.appNotReady
        }
        try Task.checkCancellation()

        let messageBody = try await DependenciesBridge.shared.attachmentContentValidator
            .prepareOversizeTextIfNeeded(MessageBody(text: trimmedText, ranges: .empty))

        let backgroundMessageFetcher = DependenciesBridge.shared.backgroundMessageFetcherFactory.buildFetcher()
        await backgroundMessageFetcher.start()
        defer {
            Task {
                await backgroundMessageFetcher.stopAndWaitBeforeSuspending()
            }
        }

        let sendPromise: Promise<Void>
        do {
            sendPromise = try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { transaction in
                guard let thread = DependenciesBridge.shared.threadStore.fetchThread(uniqueId: recipient.id, tx: transaction) else {
                    throw SignalIntentError.conversationNotFound
                }
                guard thread.shouldThreadBeVisible, thread.canSendChatMessagesToThread() else {
                    throw SignalIntentError.conversationCannotReceiveMessages
                }

                ThreadUtil.addThreadToProfileWhitelistIfEmptyOrPendingRequest(
                    thread,
                    setDefaultTimerIfNecessary: true,
                    tx: transaction,
                )

                let builder: TSOutgoingMessageBuilder = .withDefaultValues(thread: thread)
                builder.setMessageBody(messageBody)
                let dmConfig = DependenciesBridge.shared.disappearingMessagesConfigurationStore
                    .fetchOrBuildDefault(for: .thread(thread), tx: transaction)
                builder.expiresInSeconds = dmConfig.durationSeconds
                builder.expireTimerVersion = NSNumber(value: dmConfig.timerVersion)

                let outgoingMessage = TSOutgoingMessage(
                    outgoingMessageWith: builder,
                    additionalRecipients: [],
                    explicitRecipients: [],
                    skippedRecipients: [],
                    transaction: transaction,
                )
                let preparedMessage = try UnpreparedOutgoingMessage.forMessage(
                    outgoingMessage,
                    body: messageBody,
                    quotedReplyDraft: nil,
                ).prepare(tx: transaction)
                return ThreadUtil.enqueueMessagePromise(
                    message: preparedMessage,
                    limitToCurrentProcessLifetime: false,
                    isHighPriority: true,
                    transaction: transaction,
                )
            }
        } catch let error as SignalIntentError {
            throw error
        } catch {
            throw SignalIntentError.sendFailed
        }

        do {
            try await sendPromise
                .timeout(
                    seconds: 10,
                    description: "Sending Signal message",
                    timeoutErrorBlock: { SignalIntentError.sendTimedOut },
                )
                .awaitableWithUncooperativeCancellationHandling()
        } catch let error as SignalIntentError {
            throw error
        } catch {
            throw SignalIntentError.sendFailed
        }

        return .result(dialog: IntentDialog("Message sent."))
    }
}

@available(iOS 16.0, *)
struct OpenSignalConversationIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Chat"
    static var description = IntentDescription("Open a specific conversation in Signal.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    static var parameterSummary: some ParameterSummary {
        Summary("Open chat with \(\.$conversation)")
    }

    @Parameter(title: "Chat", requestValueDialog: IntentDialog("Which chat would you like to open?"))
    var conversation: SignalConversationEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ensureSignalReadyAndUnlocked()

        let threadExists = SSKEnvironment.shared.databaseStorageRef.read { tx in
            DependenciesBridge.shared.threadStore.fetchThread(uniqueId: conversation.id, tx: tx)?.shouldThreadBeVisible == true
        }
        guard threadExists else {
            throw SignalIntentError.conversationNotFound
        }

        try await prepareUIForIntentPresentation()
        SignalApp.shared.presentConversationForThread(threadUniqueId: conversation.id, action: .compose, animated: true)
        return .result()
    }
}

@available(iOS 16.0, *)
struct NewSignalMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "New Message"
    static var description = IntentDescription("Open the new message composer in Signal.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ensureSignalReadyAndUnlocked()
        try await prepareUIForIntentPresentation()
        SignalApp.shared.showNewConversationView()
        return .result()
    }
}

@available(iOS 16.0, *)
struct OpenSignalCameraIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Signal Camera"
    static var description = IntentDescription("Open the camera view in Signal.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ensureSignalReadyAndUnlocked()
        try await prepareUIForIntentPresentation()
        SignalApp.shared.showCameraCaptureView()
        return .result()
    }
}

@available(iOS 16.0, *)
struct OpenSignalSettingsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Signal Settings"
    static var description = IntentDescription("Open the Settings screen in Signal.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ensureSignalReadyAndUnlocked()
        try await prepareUIForIntentPresentation()
        SignalApp.shared.conversationSplitViewController?.showAppSettings()
        return .result()
    }
}

@available(iOS 16.0, *)
struct SignalShortcutsProvider: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendSignalMessageIntent(),
            phrases: [
                "Send a message to \(\.$recipient) in \(.applicationName)",
                "Message \(\.$recipient) on \(.applicationName)",
            ],
            shortTitle: "Send Message",
            systemImageName: "paperplane.fill",
        )
        AppShortcut(
            intent: OpenSignalConversationIntent(),
            phrases: [
                "Open chat with \(\.$conversation) in \(.applicationName)",
                "Open chat in \(.applicationName)",
            ],
            shortTitle: "Open Chat",
            systemImageName: "bubble.left.and.bubble.right.fill",
        )
        AppShortcut(
            intent: NewSignalMessageIntent(),
            phrases: ["New message in \(.applicationName)"],
            shortTitle: "New Message",
            systemImageName: "square.and.pencil",
        )
        AppShortcut(
            intent: OpenSignalCameraIntent(),
            phrases: ["Open \(.applicationName) camera"],
            shortTitle: "Open Camera",
            systemImageName: "camera.fill",
        )
        AppShortcut(
            intent: OpenSignalSettingsIntent(),
            phrases: ["Open \(.applicationName) settings"],
            shortTitle: "Settings",
            systemImageName: "gearshape.fill",
        )
    }
}
