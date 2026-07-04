//
//  EmailAppApp.swift
//  EmailApp
//
//  Created by Hritvik Singhvi on 7/2/26.
//

import SwiftUI

@main
struct EmailAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var vm = InboxViewModel()

    init() {
        AppFontRegistration.registerOnce()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
                .environment(\.font, .appBody)
                .onAppear { appDelegate.vm = vm }
                .onChange(of: vm.totalUnreadCount) { _, count in
                    NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1300, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") { vm.composeContext = .new }
                    .keyboardShortcut("n", modifiers: .command)
            }
            // Settings is an in-window dimmed modal (not a separate
            // NSWindow via a `Settings` scene), so Cmd+, needs wiring here
            // instead of coming for free.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { vm.isSettingsPresented = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Message") {
                // Cmd+R triggers whichever action Settings > Compose >
                // "Default reply behavior" names; Cmd+Shift+R always does
                // the other one, so both remain reachable regardless of
                // the setting.
                Button(AppSettings.shared.defaultReplyBehavior == .reply ? "Reply" : "Reply All") {
                    guard let message = vm.focusedMessage else { return }
                    vm.composeContext = AppSettings.shared.defaultReplyBehavior == .reply ? .reply(message) : .replyAll(message)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(vm.focusedMessage == nil)
                Button(AppSettings.shared.defaultReplyBehavior == .reply ? "Reply All" : "Reply") {
                    guard let message = vm.focusedMessage else { return }
                    vm.composeContext = AppSettings.shared.defaultReplyBehavior == .reply ? .replyAll(message) : .reply(message)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(vm.focusedMessage == nil)
                Button("Forward") { vm.focusedMessage.map { vm.composeContext = .forward($0) } }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(vm.focusedMessage == nil)
                Divider()
                Button("Archive") { vm.archiveFocused() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(vm.focusedMessage == nil)
                Button(vm.focusedMessage?.isRead == true ? "Mark as Unread" : "Mark as Read") {
                    vm.toggleReadFocused()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(vm.focusedMessage == nil)
            }
            CommandMenu("View") {
                Button("Focus Search") { vm.searchFocusTrigger += 1 }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("All Mail") { vm.providerFilter = nil }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Gmail") { vm.providerFilter = .gmail }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Outlook") { vm.providerFilter = .outlook }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }
    }
}
