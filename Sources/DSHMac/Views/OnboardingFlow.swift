import SwiftUI

// MARK: - 首跑引导（官方两步：welcome 内测声明 → DeepSeek API Key 引导）
// welcome 持久化在 ui-onboarding.welcomeNoticeVersion；key 引导纯派生、无持久化 skip。

struct OnboardingWelcomeSheet: View {
    @EnvironmentObject private var app: AppState
    @State private var busy = false
    @State private var errorText: String?

    static let body_zh = """
    感谢参与 DeepSeek Harness 开发者预览。

    本产品处于快速迭代阶段，可能存在不稳定因素，且随时会有破坏性兼容变更；请勿在生产环境或涉及重要数据的任务中使用。

    你在使用中的反馈将直接决定接下来的开发优先级。
    """
    static let body_en = """
    Thanks for joining the DeepSeek Harness developer preview.

    This build iterates quickly: expect instability and compatibility-breaking changes at any time. Do not use it for production work or tasks involving important data.

    Your feedback during use will directly drive what we build next.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L.t("欢迎使用 DeepSeek Harness", "Welcome to DeepSeek Harness"))
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(DSH.labelPrimary)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(paragraphs, id: \.self) { p in
                    Text(p)
                        .font(.system(size: 14))
                        .foregroundStyle(DSH.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let e = errorText {
                Text(e).font(.system(size: 12)).foregroundStyle(DSH.errorPrimary)
            }

            HStack {
                Spacer()
                Button {
                    Task { await acknowledge() }
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.mini) }
                        Text(L.t("继续", "Continue"))
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 36)
                    .background(Capsule().fill(DSH.businessPrimary))
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
        .padding(28)
        .frame(width: 600)
        .interactiveDismissDisabled()
    }

    private var paragraphs: [String] {
        (app.appLanguage == "en" ? Self.body_en : Self.body_zh)
            .components(separatedBy: "\n\n")
    }

    private func acknowledge() async {
        busy = true
        defer { busy = false }
        do {
            let snap = try await app.settingsDescribe()
            _ = try await app.settingsMutate(
                ns: "ui-onboarding",
                ops: [SettingsDiff.Op(op: "set", path: ["welcomeNoticeVersion"], value: .string(AppState.welcomeNoticeVersion))],
                expectedRevision: snap.revisions["ui-onboarding"]
            )
            app.showOnboardingWelcome = false
            await app.evaluateKeyOnboarding()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - DeepSeek key 引导（key-only 编辑；"稍后配置"仅完成本步）

struct OnboardingKeySheet: View {
    @EnvironmentObject private var app: AppState
    @State private var keyValue = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L.t("添加一个 API Key 开始使用", "Add an API key to get started"))
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(DSH.labelPrimary)
            Text(L.t("密钥保存在本机凭据层，仅用于调用官方接口。", "The key is stored in the local credential layer and only used for official API calls."))
                .font(.system(size: 14))
                .foregroundStyle(DSH.labelSecondary)

            SecureField("sk-...", text: $keyValue)
                .font(.system(size: 14, design: .monospaced))
                .textFieldStyle(.roundedBorder)

            if let e = errorText {
                Text(e).font(.system(size: 12)).foregroundStyle(DSH.errorPrimary)
            }

            HStack {
                Button(L.t("稍后配置", "Configure later")) {
                    app.showOnboardingKey = false
                    app.onboardingCompletedThisRun = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(DSH.labelSecondary)
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.mini) }
                        Text(L.t("保存并开始", "Save and start"))
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 36)
                    .background(Capsule().fill(canSave ? DSH.businessPrimary : DSH.labelCaption))
                }
                .buttonStyle(.plain)
                .disabled(!canSave || busy)
            }
        }
        .padding(28)
        .frame(width: 600)
        .interactiveDismissDisabled()
    }

    private var canSave: Bool {
        !keyValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            try await app.setCredential(ref: "DEEPSEEK_API_KEY", value: keyValue.trimmingCharacters(in: .whitespaces))
            app.showOnboardingKey = false
            app.onboardingCompletedThisRun = true
        } catch {
            errorText = error.localizedDescription
        }
    }
}
