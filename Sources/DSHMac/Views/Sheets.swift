import SwiftUI

// MARK: - 审批弹层（官方 ApprovalPanel 风格：内容宽卡片、蓝/灰按钮）

struct ApprovalSheet: View {
    @EnvironmentObject private var app: AppState
    let approval: DSHApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 15))
                    .foregroundStyle(DSH.labelSecondary)
                Text("请求工具权限")
                    .font(.system(size: 16, weight: .medium))
            }

            HStack(spacing: 10) {
                Text("工具")
                    .font(.system(size: 13))
                    .foregroundStyle(DSH.labelTertiary)
                    .frame(width: 40, alignment: .leading)
                Text(approval.toolName)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(DSH.labelPrimary)
                    .textSelection(.enabled)
            }
            if let reason = approval.reason, !reason.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Text("说明")
                        .font(.system(size: 13))
                        .foregroundStyle(DSH.labelTertiary)
                        .frame(width: 40, alignment: .leading)
                    Text(reason)
                        .font(.system(size: 13))
                        .foregroundStyle(DSH.labelSecondary)
                }
            }

            HStack(spacing: 12) {
                Spacer()
                Button {
                    Task { await app.resolveApproval(approval, allow: false) }
                } label: {
                    Text("拒绝")
                        .font(.system(size: 14))
                        .foregroundStyle(DSH.labelPrimary)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(Capsule().strokeBorder(DSH.borderL2, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button {
                    Task { await app.resolveApproval(approval, allow: true) }
                } label: {
                    Text("允许")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(Capsule().fill(DSH.businessPrimary))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .interactiveDismissDisabled()
    }
}

// MARK: - Agent 提问弹层（官方 QuestionComposer 风格）

struct QuestionSheet: View {
    @EnvironmentObject private var app: AppState
    let question: DSHQuestionRequest
    @State private var selections: [Int] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(DSH.labelSecondary)
                Text("Agent 需要你的回答")
                    .font(.system(size: 16, weight: .medium))
            }

            ForEach(Array(question.items.enumerated()), id: \.element.id) { qIndex, item in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = item.header {
                        Text(header)
                            .font(.system(size: 12))
                            .foregroundStyle(DSH.labelTertiary)
                    }
                    Text(item.question)
                        .font(.system(size: 14))
                        .foregroundStyle(DSH.labelPrimary)
                        .textSelection(.enabled)
                    if item.options.count > 1 {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(item.options.enumerated()), id: \.offset) { oIndex, opt in
                                Button {
                                    if qIndex < selections.count { selections[qIndex] = oIndex }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: (qIndex < selections.count && selections[qIndex] == oIndex) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 14))
                                            .foregroundStyle(DSH.businessPrimary)
                                        Text(opt.label)
                                            .font(.system(size: 14))
                                            .foregroundStyle(DSH.labelPrimary)
                                        if let desc = opt.description, !desc.isEmpty {
                                            Text(desc)
                                                .font(.system(size: 12))
                                                .foregroundStyle(DSH.labelTertiary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(qIndex < selections.count && selections[qIndex] == oIndex ? DSH.hoverBg : Color.clear)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(DSH.codeBlockBg))
            }

            HStack {
                Spacer()
                Button {
                    Task { await app.resolveQuestion(question, answers: selections) }
                } label: {
                    Text("提交回答")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(Capsule().fill(DSH.businessPrimary))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .interactiveDismissDisabled()
        .onAppear {
            selections = question.items.map { $0.options.first != nil ? 0 : -1 }
        }
    }
}

// MARK: - 模型设置窗口（侧栏入口；官方模型目录分组）

struct ModelSettingsWindow: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let sessionId: String
    @State private var catalog: DSHModelCatalog?
    @State private var loading = true
    @State private var effort: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("模型")
                    .font(.system(size: 16, weight: .medium))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DSH.labelTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            if let catalog {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(catalog.groups) { group in
                            Text(group.name)
                                .font(.system(size: 12))
                                .foregroundStyle(DSH.labelTertiary)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                            ForEach(group.models) { model in
                                modelRow(group: group, model: model)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            } else {
                ContentUnavailableView("加载中", systemImage: "cpu")
            }
        }
        .frame(width: 440, height: 520)
        .task {
            catalog = await app.refreshModels(session: sessionId)
            loading = false
        }
    }

    private func modelRow(group: DSHModelCatalog.Group, model: DSHModelCatalog.Model) -> some View {
        let isCurrent = catalog?.current.provider == group.id && catalog?.current.model == model.id
        return Button {
            Task {
                await app.selectModel(provider: group.id, model: model.id, effort: effort)
                effort = nil
                dismiss()
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .font(.system(size: 14, weight: isCurrent ? .medium : .regular))
                            .foregroundStyle(DSH.labelPrimary)
                        if isCurrent {
                            Text("当前")
                                .font(.system(size: 10))
                                .foregroundStyle(DSH.businessPrimary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(DSH.businessPrimary.opacity(0.12)))
                        }
                    }
                    Text(model.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DSH.labelTertiary)
                }
                Spacer()
                if !model.efforts.isEmpty {
                    Menu {
                        ForEach(model.efforts) { e in
                            Button(e.name) { effort = e.id }
                        }
                    } label: {
                        Text(effort.map { name($0, in: model) } ?? "推理力度")
                            .font(.system(size: 12))
                            .foregroundStyle(DSH.labelSecondary)
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(DSH.selectorFill))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isCurrent ? DSH.hoverBg : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func name(_ id: String, in model: DSHModelCatalog.Model) -> String {
        model.efforts.first { $0.id == id }?.name ?? id
    }
}
