import SwiftUI
import AppKit

// MARK: 插件浏览器
//
// 挂在混音器窗口上的一张表：搜索框 + 本机所有 AU 效果器，点一下就装进那六格里的一格。
// 清单来自每个 .component 的 Info.plist（实测 772 条 · 最快 28.5 ms），不是注册表 ——
// AudioComponentFindNext 在这台机器上全量遍历 aufx 跑四分多钟没走完，见 PluginCatalog。
// 列表里的名字只是身份，代码一行都还没加载：真正实例化在选中之后才发生。
// ESC 和「取消」都只是把这张表收起来：那一格原来有什么就还是什么，动过的只有装载那条路。

struct PluginBrowser: View {
    @ObservedObject var vm: PlayerViewModel
    let target: SlotTarget

    @State private var query = ""
    @State private var all: [AUPlugin] = []
    @State private var selection: AUPlugin.ID?
    @FocusState private var searchFocused: Bool

    private var results: [AUPlugin] { PluginCatalog.matches(all, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("插槽 \(target.index + 1)")
                    .font(.system(size: 11, weight: .semibold))
                Text("轨 \(target.side == .a ? "A" : "B")")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(results.count) / \(all.count)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            TextField("搜索插件", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { chooseCurrentSelection() }
                .onChange(of: query) { _ in
                    // 换了搜索词就把高亮挪到第一条，回车才有落点。必须交还给下一轮再改：
                    // 在 List 自己的更新里写 selection 会被 AppKit 判成表格代理重入
                    // （实测警告 "reentrant operation in its NSTableView delegate"）。
                    DispatchQueue.main.async { selection = results.first?.id }
                }
            List(selection: $selection) {
                ForEach(results) { plugin in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plugin.name)
                            .font(.system(size: 11))
                        Text(plugin.subtitle)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .tag(plugin.id)
                    .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                    // 鼠标指到哪一条就亮哪一条，点一下直接装进去（Logic 的插件菜单也是这个手感）。
                    .onHover { inside in
                        guard inside else { return }
                        // 同 onChange：表正在更新时写 selection 会被 AppKit 判成代理重入。
                        DispatchQueue.main.async { selection = plugin.id }
                    }
                    .onTapGesture { load(plugin) }
                }
            }
            .overlay {
                if results.isEmpty {
                    Text(all.isEmpty ? "未在本机找到 AU 插件" : "没有匹配项")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                Button("取消") { vm.closeBrowser() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("载入") { chooseCurrentSelection() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(12)
        .frame(width: 320, height: 380)
        .onAppear {
            searchFocused = true
            loadCatalogIfNeeded()
        }
    }

    private func loadCatalogIfNeeded() {
        guard all.isEmpty else { return }
        // plist 读取只要几十毫秒，仍然放到后台：主线程在这期间还能画走带。
        DispatchQueue.global(qos: .userInitiated).async {
            let catalog = PluginCatalog.effects()
            DispatchQueue.main.async {
                all = catalog
                // 同一条理由：表正在按新数据重建，这一轮里就写 selection 会被判重入。
                DispatchQueue.main.async { if selection == nil { selection = results.first?.id } }
            }
        }
    }

    private func chooseCurrentSelection() {
        guard let id = selection, let plugin = all.first(where: { $0.id == id }) else { return }
        load(plugin)
    }

    private func load(_ plugin: AUPlugin) {
        vm.loadPlugin(plugin, at: target.index, for: target.side)
        vm.closeBrowser()
    }
}
