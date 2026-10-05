import SwiftUI

struct CopilotFloatingButton: View {
    @ObservedObject private var copilot = CopilotService.shared

    var body: some View {
        Button { copilot.showsPopover.toggle() } label: {
            Label {
                Text("GitHub Copilot")
            } icon: {
                Image("Copilot")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: DS.Layout.barControlGlyph, height: DS.Layout.barControlGlyph)
                    .opacity(copilot.canSuggest ? 1 : 0.6)
                    .overlay(alignment: .bottomTrailing) {
                        if copilot.phase == .attention {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: DS.Layout.symbolGlyph))
                                .foregroundStyle(DS.StatusColors.warning)
                                .background(.background, in: Circle())
                                .accessibilityHidden(true)
                        } else if !copilot.canSuggest, copilot.hasAccount {
                            Image(systemName: "pause.circle.fill")
                                .font(.system(size: DS.Layout.symbolGlyph))
                                .background(.background, in: Circle())
                                .accessibilityHidden(true)
                        }
                    }
            }
            .labelStyle(.iconOnly)
            .frame(width: DS.Layout.slot, height: DS.Layout.slot)
        }
        .modifier(GlassIconControlStyle())
        .background(ArrowCursorZone(active: true))
        .help("Show GitHub Copilot — \(copilot.statusText)")
        .accessibilityLabel("GitHub Copilot")
        .accessibilityValue(copilot.statusText)
        .popover(isPresented: $copilot.showsPopover, arrowEdge: .bottom) {
            CopilotPopover(copilot: copilot)
        }
    }
}

struct CopilotPopover: View {
    @ObservedObject var copilot: CopilotService
    @State private var contentHeight = DS.Layout.inspectionHeight

    var body: some View {
        ScrollView {
            content
                .padding(DS.Space.xl)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if height.isFinite, height > 0 { contentHeight = ceil(height) }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: DS.Layout.copilotPopoverWidth,
               height: min(contentHeight, DS.Layout.copilotPopoverMaxHeight))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            HStack {
                Text("GitHub Copilot").font(.headline)
                Spacer()
                if copilot.isBusy { ProgressView().controlSize(.small) }
            }
            if let account = copilot.account {
                Text("Signed in as @\(account)").font(.callout).textSelection(.enabled)
            }
            Text(copilot.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let code = copilot.deviceCode {
                Text(code)
                    .font(.title2.monospaced())
                    .textSelection(.enabled)
                    .accessibilityLabel("GitHub device code: \(code)")
                Text("Paste this one-time code into GitHub to connect your account.")
                    .font(.caption).foregroundStyle(.secondary)
                if copilot.phase == .deviceCode {
                    Button("Copy Code and Open GitHub") { copilot.continueSignIn() }
                        .buttonStyle(.borderedProminent)
                }
            }

            if let notice = copilot.notice {
                Divider()
                Text(notice.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                ForEach(notice.actions.indices, id: \.self) { index in
                    Button(String((notice.actions[index]["title"] as? String ?? "Continue").prefix(120))) {
                        copilot.respondToNotice(notice.id, action: index)
                    }
                }
                Button("Dismiss") { copilot.respondToNotice(notice.id, action: nil) }
            }

            if copilot.hasAccount {
                Divider()
                Toggle("Code Suggestions", isOn: Binding(get: { copilot.isEnabled }, set: copilot.setEnabled))
                    .toggleStyle(.switch)
                if let workspace = copilot.workspaceURL {
                    Toggle("Disable for This Project", isOn: Binding(get: { copilot.isProjectDisabled }, set: copilot.setProjectDisabled))
                        .help("Disable Copilot in \(workspace.lastPathComponent)")
                }
            }

            if copilot.isBusy || copilot.phase == .deviceCode {
                Button("Cancel") { copilot.cancelSignIn() }
            } else {
                HStack {
                    if !copilot.hasAccount {
                        Button("Sign in with GitHub") { copilot.beginSignIn() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Sign Out") { copilot.signOut() }
                        Spacer()
                        if copilot.phase == .attention, copilot.isEnabled {
                            Button("Retry") { copilot.reconnect() }
                        }
                    }
                }
            }
            if !copilot.hasAccount {
                Text("The first sign-in downloads GitHub’s Copilot helper. Your GitHub account needs Copilot access.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Copilot sends code context to GitHub to generate suggestions. Turning suggestions off stops sharing code.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: "https://github.com/settings/copilot") {
                Link("Manage Copilot on GitHub", destination: url).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CopilotCommands: Commands {
    @ObservedObject private var copilot = CopilotService.shared

    var body: some Commands {
        CommandMenu("Copilot") {
            Button("Show GitHub Copilot") { copilot.showsPopover = true }
            Divider()
            Toggle("Code Suggestions", isOn: Binding(get: { copilot.isEnabled }, set: copilot.setEnabled))
                .disabled(!copilot.hasAccount)
            Toggle("Disable for This Project", isOn: Binding(get: { copilot.isProjectDisabled }, set: copilot.setProjectDisabled))
                .disabled(copilot.workspaceURL == nil)
            Divider()
            Button("Sign in with GitHub…") {
                copilot.showsPopover = true
                copilot.beginSignIn()
            }.disabled(copilot.isBusy || copilot.hasAccount)
            Button("Copy Code and Open GitHub") { copilot.continueSignIn() }
                .disabled(copilot.phase != .deviceCode)
            Button("Cancel Connection") { copilot.cancelSignIn() }
                .disabled(!copilot.isBusy && copilot.phase != .deviceCode)
            Button("Retry Connection") { copilot.reconnect() }
                .disabled(!copilot.isEnabled || copilot.isBusy)
            Button("Sign Out") { copilot.signOut() }
                .disabled(!copilot.hasAccount || copilot.isBusy)
        }
    }
}
