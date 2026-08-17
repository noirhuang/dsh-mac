import SwiftUI
import AppKit

// MARK: - 官方 ModelSelect 复刻：两级菜单（root 模型/力度行对 → 分组模型列表 / 力度列表）
// 触发器 28px 胶囊：模型名 · 力度名(caption) + chevron（开时旋转）；菜单 240px/12 圆角/max 360。
// 语义：选模型自动携带 defaultEffort；力度=undefined 表示保留 provider 默认。

struct ModelSeat: View {
    @EnvironmentObject private var app: AppState
    let sessionId: String
    let catalog: DSHModelCatalog

    @State private var open = false
    @State private var pane: Pane = .root
    @State private var toast: String?
    @State private var toastSeq = 0

    enum Pane { case root, model, effort }

    // 当前选择（官方：目录 join 后的 choice）
    private var currentChoice: (group: DSHModelCatalog.Group, model: DSHModelCatalog.Model)? {
        guard let group = catalog.groups.first(where: { $0.id == catalog.current.provider }),
              let model = group.models.first(where: { $0.id == catalog.current.model }) else { return nil }
        return (group, model)
    }

    /// 当前模型是否有力度（官方 reasoning != undefined）
    private var hasEffort: Bool {
        !(currentChoice?.model.efforts.isEmpty ?? true)
    }

    /// 生效力度（选择值 ?? provider 默认）
    private var effectiveEffort: String? {
        catalog.current.reasoningEffort ?? currentChoice?.model.defaultEffort
    }

    private var effortLabel: String? {
        guard hasEffort else { return nil }
        if let e = effectiveEffort {
            return currentChoice?.model.efforts.first { $0.id == e }?.name ?? e
        }
        return L.t("提供方默认", "Provider default")
    }

    var body: some View {
        // 触发器（官方 ToggleButton：28px 胶囊 24 圆角，13/500 secondary + 力度 caption）
        Button {
            open.toggle()
            pane = .root
        } label: {
            HStack(spacing: 4) {
                Text(currentChoice?.model.name ?? L.t("选择模型", "Select model"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DSH.labelSecondary)
                    .lineLimit(1)
                if let e = effortLabel {
                    Text("· \(e)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DSH.labelCaption)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DSH.labelCaption)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 28)
            .background(Capsule().fill(Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(HoverButtonStyle(hoverFill: DSH.hoverBg, shape: AnyShape(Capsule())))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            menuBody
                .frame(width: 240)
                .frame(maxHeight: 360)
                .background(DSH.elevatedFill)
        }
        .overlay(alignment: .top) {
            if let t = toast {
                Text(t)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color(nsColor: .systemRed)))
                    .offset(y: -34)
                    .task(id: toastSeq) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        self.toast = nil
                    }
            }
        }
    }

    // MARK: 菜单三面板

    @ViewBuilder
    private var menuBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch pane {
            case .root:
                // 官方两行 cell（40px：label + 当前值 + 右 chevron）
                cell(L.t("模型", "Model"), value: currentChoice?.model.name ?? "—") { pane = .model }
                if hasEffort {
                    cell(L.t("推理力度", "Effort"), value: effortLabel ?? "—") { pane = .effort }
                }
            case .model:
                modelPane
            case .effort:
                effortPane
            }
        }
        .padding(4)
    }

    private func cell(_ label: String, value: String, drill: @escaping () -> Void) -> some View {
        Button(action: drill) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(DSH.labelPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 14))
                    .foregroundStyle(DSH.labelTertiary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DSH.labelTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(HoverButtonStyle(hoverFill: DSH.hoverBg, shape: AnyShape(RoundedRectangle(cornerRadius: 10))))
    }

    /// 模型面板显式高度（官方 max 360 内滚动；避免 popover 内 ScrollView 高度塌陷）
    private var modelPaneHeight: CGFloat {
        let rows = catalog.groups.reduce(0) { $0 + $1.models.count }
        let titles = catalog.groups.filter { !$0.models.isEmpty }.count
        let failuresH = catalog.failures.isEmpty ? 0 : catalog.failures.count * 44 + 8
        return min(CGFloat(rows) * 44 + CGFloat(titles) * 28 + 16 + CGFloat(failuresH), 360)
    }

    private var modelPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(catalog.groups) { group in
                    // 分组标题（官方 sticky 标题：12/500 tertiary）
                    Text(group.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DSH.labelTertiary)
                        .padding(.horizontal, 8)
                        .padding(.top, 5)
                        .padding(.bottom, 3)
                    ForEach(group.models) { model in
                        let selected = catalog.current.provider == group.id && catalog.current.model == model.id
                        optionRow(
                            title: model.name,
                            description: model.description,
                            selected: selected
                        ) {
                            choose(provider: group.id, model: model)
                        }
                    }
                }
                if catalog.groups.allSatisfy({ $0.models.isEmpty }) {
                    Text(L.t("没有可用模型", "No models available"))
                        .font(.system(size: 13))
                        .foregroundStyle(DSH.labelTertiary)
                        .padding(10)
                }
                // 分组失败提示（官方 warning 行）
                ForEach(catalog.failures, id: \.id) { failure in
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: .systemOrange))
                        Text("\(failure.name)：\(failure.message)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DSH.hoverBgSolid))
                }
            }
        }
        .frame(height: max(modelPaneHeight, 120))
    }

    private var effortPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                // "提供方默认"仅当 defaultEffort 未定义（官方语义）
                if let model = currentChoice?.model, model.defaultEffort == nil {
                    optionRow(title: L.t("提供方默认", "Provider default"), description: nil, selected: effectiveEffort == nil) {
                        chooseEffort(nil)
                    }
                }
                ForEach(currentChoice?.model.efforts ?? []) { effort in
                    let selected = effectiveEffort == effort.id
                    optionRow(title: effort.name, description: effort.description, selected: selected) {
                        chooseEffort(effort.id)
                    }
                }
                if currentChoice?.model.efforts.isEmpty ?? true {
                    Text(L.t("该模型没有可选力度", "No effort levels for this model"))
                        .font(.system(size: 13))
                        .foregroundStyle(DSH.labelTertiary)
                        .padding(10)
                }
            }
        }
        .frame(height: min(CGFloat((currentChoice?.model.efforts.count ?? 0) + 2) * 44 + 8, 360))
    }

    private func optionRow(title: String, description: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DSH.labelPrimary)
                        .lineLimit(1)
                    if let d = description, !d.isEmpty {
                        Text(d)
                            .font(.system(size: 12))
                            .foregroundStyle(DSH.labelTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DSH.labelPrimary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(HoverButtonStyle(hoverFill: DSH.hoverBg, shape: AnyShape(RoundedRectangle(cornerRadius: 10))))
    }

    // MARK: 选择语义（官方：选模型带 defaultEffort；选已选模型只关菜单；失败 toast）

    private func choose(provider: String, model: DSHModelCatalog.Model) {
        if catalog.current.provider == provider && catalog.current.model == model.id {
            open = false
            return
        }
        Task {
            do {
                try await app.selectModelRaw(sessionId: sessionId, provider: provider, model: model.id, reasoningEffort: model.defaultEffort)
                open = false
            } catch {
                toastSeq += 1
                toast = error.localizedDescription
            }
        }
    }

    private func chooseEffort(_ effort: String?) {
        if effectiveEffort == effort {
            open = false
            return
        }
        Task {
            do {
                try await app.selectModelRaw(
                    sessionId: sessionId,
                    provider: catalog.current.provider,
                    model: catalog.current.model,
                    reasoningEffort: effort
                )
                open = false
            } catch {
                toastSeq += 1
                toast = error.localizedDescription
            }
        }
    }
}
