# AB-Player

macOS 上的双轨音频对比播放器：A、B 两轨同窗，带波形、标记、效果器链与导出。

![双轨视图与混音器](https://github.com/mio-furuhashi/ab-player/releases/download/v2.2.0/picA.png)

## 使用方式

- macOS 14.0 或更高。效果器使用系统或第三方 Audio Unit，应用本身不打包插件。
- 范围裁切导出需要系统安装 [ffmpeg](https://ffmpeg.org)（自动在 `/usr/local/bin`、`/opt/homebrew/bin` 与 `PATH` 中查找；渲染导出不依赖 ffmpeg，未安装也不影响其他功能）。

```bash
brew install ffmpeg
```

工程文件（`AB-Player.xcodeproj`）随仓库提交，可直接用 Xcode 打开，或：

```bash
xcodebuild -project AB-Player.xcodeproj -target AB-Player -configuration Release build
# 产物：build/Release/AB-Player.app
```

工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 管理，改动 `project.yml` 后 `xcodegen generate` 重新生成。

> 请使用 Release 构建：Debug 里带着验证用的探针与日志，播放时 CPU 占用明显偏高。

## 许可

本项目以 **GPL-3.0-or-later** 许可证开源。任何分发版本（含修改与衍生作品）必须同样以 GPL-3.0 公开完整源代码，详见 [LICENSE](LICENSE)。

## 功能特性

- **A/B 无缝切换**：两条轨道同时装载，`F` 只切音量不重启播放。
- **单轨视图 / 双轨视图 / ABX**：单轨视图里 A/B 同步播放、同步拖动进度；双轨视图上下两组波形各自独立；ABX 随机隐藏 X 轨做多轮盲听，成绩附单侧二项检验的置信度。
- **编辑模式（`⌘4`）**：A、B 各一条链路 —— pre-gain → 声像 → 6 格插件槽 → 推子 → 主混音；混音器（`⌘5`）带电平表、声像、推子与可重命名的轨道名。
- **视频窗口（`⌘6`）**：单画面跟随当前监听轨，`F` 换轨时画面无缝衔接。支持 mp4 / mov / m4v，H.264 / HEVC / ProRes。
- **波形与标记**：垂直/水平缩放（最高 200×）、滚轮平移、播放头独立 20Hz 刷新；`` ` `` 打双轨全局标记、`M` 打单轨标记，带章节的文件可把章节转成标记。
- **时间偏移**：双轨视图里给单轨挪动起点，只改监听与时间刻度，不影响标记、范围与导出。
- **导出**：「裁切」走 ffmpeg（旁通插件，以源编码输出），「渲染后导出」把 pre-gain、声像、插件、推子烤进文件，位深 16 bit / 24 bit / 32 bit float 可选。另有并发的响度检测（LUFS / dBTP / LU）。
- **播放列表与工程**：主列表＋备用列表，`⌘` 拖动调序，`Q` / `E` 设为 A / B 轨；`⌘S` 存工程（`.abpl` 只存会话参数，不复制音频）。标记、范围、插件链等改动留 30 步快照。

## 用法

![单轨视图与信息窗口](https://github.com/mio-furuhashi/ab-player/releases/download/v2.2.0/picB.png)

| 按键 | 功能 | 按键 | 功能 |
| --- | --- | --- | --- |
| `空格` | 播放 / 暂停 | `F` | A/B 无缝切换 |
| `H` / `⌃H` | 停止两轨 / 仅当前轨 | `K` | 两轨同时播放 / 暂停 |
| `⌘1` … `⌘6` | 单轨视图 / 双轨视图 / ABX / 编辑模式 / 混音器 / 视频窗口 | `Q` / `E` | 选中项设为 A / B 轨 |
| `R` / `C` / `⌘R` | 框选范围 / 区间循环 / 清除范围 | `` ` `` / `M` | 双轨标记 / 单轨标记 |
| `⌘E` | 导出… | `⌘Z` / `⌘⇧Z` | 撤销 / 重做 |
| `I` / `P` | 信息窗口 / 开关播放列表栏 | `⌘,` / `⌘?` | 设置… / 使用帮助 |

全部按键均可在「设置…（`⌘,`）→ 快捷键」中自定义，录制支持 `⌘ ⌃ ⌥ ⇧`。
其余用法详见程序内「帮助」页面（`⌘?`）。

## 数据存储

设置、快捷键、每个音频文件的标记以及备用列表均保存在本机的 UserDefaults（bundle id `com.abplayer.app`）中；轨道预设落在 `~/Library/Application Support/AB-Player/轨道预设`，工程文件（`.abpl`）默认存在「文稿」。不涉及网络，不上传任何数据。
