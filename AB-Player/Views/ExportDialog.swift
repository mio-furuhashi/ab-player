import SwiftUI
import AppKit

// MARK: 导出对话框
//
// 菜单顶上多一项「导出…」（⌘E），对话框里摆两个互斥选项 ——
// 「裁切，旁通所有插件」和「渲染，应用插件效果」。前者就是原来那两条无插件导出
// 走的路（ffmpeg 直接搬样本，插件一个字节都不算），后者交给 RenderExportService
// 离线渲染。裁切那一项忽略文件名输入，所以选中它的
// 时候文件名栏和位深栏一起灰掉。

enum ExportScope: String, CaseIterable, Hashable {
    case current
    case all

    var label: String { self == .current ? "当前轨道范围" : "全部轨道范围" }
}

enum ExportMode: Hashable {
    case trim
    case render

    var label: String {
        switch self {
        case .trim: return "裁切，旁通所有插件"
        case .render: return "渲染，应用插件效果"
        }
    }
}

final class ExportDialogModel: ObservableObject {
    @Published var scope: ExportScope { didSet { refreshDefaultName() } }
    /// 换模式，文件名栏跟着换：裁切那一档摆的是实际会写出去的
    /// `clip_原名_[开始_结束]`，渲染那一档才是可输入的 reMix_ 那份。见 `trimPreviewName`。
    @Published var mode: ExportMode
    @Published var bitDepth: ExportBitDepth { didSet { refreshDefaultName() } }
    @Published var fileName: String
    /// 名字栏还停在默认值上时，换轨道/换位深会跟着刷新；用户自己打过的就不动了。
    @Published private var nameIsDefault = true
    @Published var directory: URL?
    @Published var progress: Double?
    /// 只剩导出前的两格校验（没选目录 / 没有可渲染的轨道）。真跑起来的成败改由弹窗报，
    /// 不再用这一行。
    @Published var errorText: String?

    var isWorking: Bool { progress != nil }

    private weak var vm: PlayerViewModel?

    init(vm: PlayerViewModel, scope: ExportScope, mode: ExportMode) {
        self.vm = vm
        self.scope = scope
        self.mode = mode
        self.bitDepth = .s24
        self.fileName = ""
        // 上次选过的目录直接接着用：指定一次就够（规格：输出目录写进配置）。
        self.directory = SettingsStore.shared.exportDirectory
        refreshDefaultName()
    }

    /// 对话框里那几行「A 轨 0:12–1:05」：改范围、改模式都会跟着变。
    var laneSummary: String {
        guard let vm else { return "" }
        return vm.exportLanes(for: scope).map { lane in
            "\(lane.side == .a ? "A" : "B") 轨 \(stamp(lane.start))–\(stamp(lane.end))"
        }.joined(separator: " · ")
    }

    /// 渲染这一项要说清楚它算进哪些东西，不然用户以为只是换个格式写文件。
    var modeHint: String {
        switch mode {
        case .trim: return "仅裁切，无改变。\n名称格式：clip_（原名）_[MM-SS_MM-SS]，时间码提示[开始-结束]在原文件中的时间位置。"
        case .render:
            guard let vm else { return "" }
            return vm.editMode
                ? "离线渲染，将通道条设置应用并导出为新文件。源文件不受影响。"
                : "当前未进入编辑模式，仅可改变位深。"
        }
    }

    func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory ?? SettingsStore.shared.exportDirectory
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        directory = picked
        SettingsStore.shared.exportDirectory = picked
    }

    func export(dismiss: @escaping () -> Void) {
        guard let vm, !isWorking else { return }
        errorText = nil
        guard let directory else {
            errorText = "请选择输出目录。"
            return
        }
        switch mode {
        case .trim:
            progress = 0.01
            // 成败的报法在 PlayerViewModel 那头（口径：全成只提示音、AV 回落弹一句、
            // 没成的逐轨点名），对话框里那行内嵌橙字撤了 —— 弹窗已经把它该说的说了。
            vm.runTrimExport(for: scope, directory: directory) { [weak self] allSucceeded in
                guard let self else { return }
                self.progress = nil
                if allSucceeded { dismiss() }
            }
        case .render:
            let requests = vm.renderRequests(for: scope, typedName: fileName,
                                             bitDepth: bitDepth, directory: directory)
            guard !requests.isEmpty else {
                errorText = "没有可渲染的轨道"
                return
            }
            progress = 0
            RenderExportService.run(requests,
                                    progress: { [weak self] fraction in
                                        self?.progress = max(0.01, fraction)
                                    },
                                    completion: { [weak self] result in
                                        guard let self else { return }
                                        self.progress = nil
                                        switch result {
                                        case .failure(let error):
                                            // 和裁切同一个报法：弹窗说明，对话框留着好改。
                                            ProjectStore.notify("❌导出失败：\(error.localizedDescription)")
                                        case .success:
                                            dismiss()
                                        }
                                    })
        }
    }

    private func stamp(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// 「裁切，旁通所有插件」档在灰栏里显示的名字 —— 就是实际写出去的那一串。
    /// 走的是现算的 getter，不是把 fileName 顶掉：用户先前在渲染档打的那份得留着，
    /// 切回来还在。
    var trimPreviewName: String {
        guard let vm, let lane = vm.exportLanes(for: scope).first else { return "" }
        return FFmpegService.clipFileName(inputURL: lane.url,
                                          startTime: lane.start, endTime: lane.end)
    }

    private func refreshDefaultName() {
        guard nameIsDefault, let vm, let lane = vm.exportLanes(for: scope).first else { return }
        fileName = RenderExportService.defaultRenderName(sourceURL: lane.url, bitDepth: bitDepth)
    }

    /// 名字栏一改就不再跟默认值走；清空了算「还是默认」。
    func nameEdited(_ newValue: String) {
        nameIsDefault = newValue.isEmpty
        if newValue.isEmpty { refreshDefaultName() }
    }
}

struct ExportDialogView: View {
    @ObservedObject var vm: PlayerViewModel
    @StateObject private var model: ExportDialogModel
    let onDismiss: () -> Void

    init(vm: PlayerViewModel, scope: ExportScope, mode: ExportMode, onDismiss: @escaping () -> Void) {
        self.vm = vm
        self.onDismiss = onDismiss
        _model = StateObject(wrappedValue: ExportDialogModel(vm: vm, scope: scope, mode: mode))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导出")
                .font(.system(size: 13, weight: .semibold))

            Picker("范围", selection: $model.scope) {
                ForEach(ExportScope.allCases, id: \.self) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.isWorking)

            Text(model.laneSummary)
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Picker("模式", selection: $model.mode) {
                Text(ExportMode.trim.label).tag(ExportMode.trim)
                Text(ExportMode.render.label).tag(ExportMode.render)
            }
            .pickerStyle(.radioGroup)
            .disabled(model.isWorking)

            Text(model.modeHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("文件名")
                    .frame(width: 56, alignment: .leading)
                // 裁切档：栏灰着、显示现算的那串 clip_ 名（只预览，打不进字）；渲染档：
                // 正常可输入。切换选项时这一格自己跟着换。
                TextField("reMix_原名.wav", text: Binding(
                    get: { model.mode == .trim ? model.trimPreviewName : model.fileName },
                    set: { model.fileName = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.mode == .trim || model.isWorking)
                    .onChange(of: model.fileName) { model.nameEdited($0) }
            }

            HStack {
                Text("位深")
                    .frame(width: 56, alignment: .leading)
                Picker("位深", selection: $model.bitDepth) {
                    ForEach(ExportBitDepth.allCases) { depth in
                        Text(depth.label).tag(depth)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 140)
                .disabled(model.mode == .trim || model.isWorking)
            }

            HStack {
                Text("输出目录")
                    .frame(width: 56, alignment: .leading)
                Text(model.directory?.path ?? "未选择")
                    .font(.system(size: 10))
                    .foregroundColor(model.directory == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("选择…") { model.pickDirectory() }
                    .disabled(model.isWorking)
            }

            if let progress = model.progress {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                    Text("渲染中 \(Int(progress * 100))%")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            if let errorText = model.errorText {
                Text(errorText)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.mode == .render ? "渲染并导出" : "导出") {
                    model.export(dismiss: onDismiss)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
