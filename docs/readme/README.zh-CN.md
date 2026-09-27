# Aagedal Media Converter

[English](../../README.md) · [Norsk bokmål](README.nb.md) · [Español](README.es.md) · [简体中文](README.zh-CN.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Deutsch](README.de.md) · [日本語](README.ja.md) · [Português (Brasil)](README.pt-BR.md)

<img alt="Aagedal Media Converter" src="https://github.com/user-attachments/assets/213e64a6-f382-4562-b4cf-797ad1e0f368" />

这是一款轻量、简洁的 macOS 应用，界面简单，却内置了丰富而强大的功能。底层使用 FFmpeg、MPV、SwiftMediaMetadata、yt-dlp、rclone 和 whisper.cpp，完全采用 Swift / SwiftUI 编写。

完全免费、开源。注重隐私，所有处理均在本地进行。可选的更新检查默认开启，也可以关闭。

这是一个出于热爱的个人项目。我为了提高自己的工作效率而开发了它，也想分享给其他人。请注意，应用的大部分代码采用了 AI 辅助的「vibe coding」方式开发。

---

## 安装

### Homebrew
```bash
brew tap aagedal/tap && brew install --cask aagedal-media-converter
```

### 手动下载
[下载当前版本](https://github.com/aagedal/Aagedal-Media-Converter/releases/latest)

---

## 主要功能

- **启动迅速，易于使用**
- **批量转换**几乎所有视频和音频文件（可替代 Shutter Encoder 或 Handbrake）
- **全屏播放**，支持时间码显示和 JKL 播放控制（可替代 IINA 或 VLC）
- **查看和比较元数据**，包括检测是否存在 C2PA 信息（可替代 MediaInfo）
- **下载**网站视频，支持定时下载和直播下载
- **屏幕录制**，包含系统音频，可选独立麦克风音轨（可替代 OBS）
- **转录**视频和音频，生成 SRT 字幕
- 转换后**上传**至服务器

- 在支持序列预览和波纹修剪的时间线上**拼接**片段
- 通过可选启用的代理访问，使用**本地 MCP 自动化转换**

### 通用功能

- 预览和编码几乎所有视频文件
- 导入和导出**图像序列**（PNG、TIFF、EXR、DPX、JPEG 2000 等），支持关联音频和设置帧率
- 导出包含 JPEG 2000 XYZ 图像和 PCM 音频的 **DCP（数字电影包）**
- 导出实验性的 **IMF App 2e 和 RDD 45** 包，在交付工具中进行验证
- 批量转换、监视文件夹和进度条
- 修剪时长、裁剪画面、重新分配或删除音轨，以及合并格式相同的片段
- 查看和比较元数据
- 丰富的[键盘快捷键](../../KeyboardShortcuts.md)，大部分功能无需鼠标即可操作
- 多种自定义设置
- 自动检查更新并显示低干扰通知，可关闭
- 下载 YouTube、TikTok 等网站的视频（yt-dlp）
- 转录为 SRT 字幕（whisper.cpp）
- 上传至 FTP（rclone）
- 检查 C2PA 签名（SwiftMediaMetadata）
- HDR 屏幕录制，支持系统音频和可选的独立麦克风音轨

### 批量转换

- 自动编码队列中的所有文件
- 拖放文件以调整编码顺序
- 编码过程中可从队列中移除文件

### 监视文件夹

- 自动导入指定文件夹中的文件
- 可与手动拖放导入同时使用，所有编码任务集中在同一窗口
- 可选择自动删除或忽略监视文件夹中的文件
- 点击主窗口工具栏中的眼睛图标启用

### 文件预览

- 支持 JKL 和方向键等常用剪辑快捷键
- 简单的音频电平表（⌘A）
- 对兼容文件使用 macOS 原生播放器，即使倒放也能流畅播放
- 对 macOS 不支持的文件自动使用 MPVKit 播放器，但倒放的可靠性较低

### 快速调整

- 使用拖动手柄或 I/O 快捷键修剪时长
- 从源文件复制时间码、手动设置或移除时间码
- 使用画面上的控件裁剪视频，在修剪视图中按 C 或点击裁剪图标即可进入
    - 不适用于 Stream Copy 预设
- 删除或重排音轨
    - 不适用于 Stream Copy 预设

### 合并队列文件

- 合并编码格式、分辨率、帧率、位深和音轨相同的文件
- 队列中的第一个片段决定时间码和画面裁剪设置
- 在拼接时间线中编辑分组，支持胶片条缩略图、序列播放、波纹修剪、重排、分割、范围删除和撤销。
- 使用 Stream Copy 修剪并合并，无需重新编码。切点取决于源文件的关键帧，可能与选定边界不同；部分元数据可能丢失。
- 导出 Resolve EDL 片段标记和内嵌章节，已有章节可选择保留或替换。

### 从相机存储卡导入

- 导入前按存储卡文件夹和录制日期查看片段。
- 明确标记连续录制的后续片段，也可在间隔超过两小时后拆分分组。兼容性检查有助于识别可拼接的片段。

### 本地代理访问

启用 **Settings → Agent Access**，授权源文件夹，并复制 MCP 客户端的配置。随附辅助程序允许代理浏览和检查已授权的媒体、规划转换、提交任务、跟踪进度，以及取消应用队列中的任务。全部 17 个内置预设均可使用；自定义 FFmpeg 预设除外。IMF 导出属于实验性功能。

已接受的任务在客户端断开连接后仍会继续。计划有效期为 15 分钟，已结束任务的结果保留 30 天。代理导出会禁用输出时间码。文件夹授权、客户端配置和任务恢复详见[配置与工作流程指南](../../Documentation/LOCAL_AGENT_ACCESS.md)。

### 生成音频波形动画

- 为纯音频文件生成波形动画
- 五种预设，支持颜色和归一化选项

### 按源分辨率和位深捕获静态图像

修剪播放器中的相机按钮可按源分辨率捕获静态图像，默认格式为 JPEG XL。可在设置中为不同位深选择图像格式，也可指定如何处理带有 Alpha 通道的视频。

### 导出和文件命名

- 默认移除空格和特殊字符，将 æ、ø、å 替换为 ae、o、aa
- 预览处理后的文件名
- 文件已存在时显示警告
- 编码完成后，点击图标可在导出目录中显示转换后的文件
- 另一个图标支持将输出文件拖至其他应用或目录
- 在设置中选择默认预设
- 设置默认导出位置

### 元数据

- 每个文件都有可选的注释字段，可用于写入署名等信息
- 可在注释前添加日期标签（Generated [YYYYMMDD]）、前缀和后缀
- 查看和比较元数据

### VideoLoop 预设的 15 秒自动播放提醒

浏览器经常阻止较长的有声循环视频自动播放。当 VideoLoop 预设应用于超过 15 秒的片段时，应用会显示黄色 ⚠️ 图标，提醒你缩短片段或选择其他预设。

### App Intents

1. 添加至编码队列。
2. 使用默认预设立即转换视频。

---

## 导出预设

所有预设均可设为启动时的默认预设。除默认预设外，其他预设都可以从选择器中隐藏。

#### Video Loop

针对无声、无缝循环视频优化。采用 x264、CRF 23（约 3–9 Mbps 可变码率）编码，移除音频，并将短边限制为 1080 像素，便于网页播放。片段超过 15 秒时会显示时长提醒。

#### Video Loop w/ Audio

与无声版本使用相同的 x264 设置，但保留所有音轨并编码为 128 kbps AAC，短边仍限制为 1080 像素。

#### H.264 / AVC

兼容性广泛的 H.264/AVC 编码。可选择快速的 VideoToolbox 硬件编码，或注重质量、支持 CRF 控制的 libx264 软件编码。支持 MP4、MOV 和 MKV 容器。

#### H.265 / HEVC

现代的 10 位 H.265/HEVC 编码。VideoToolbox 硬件编码可加快导出，也可选择 libx265 软件编码以提高压缩效率。

#### AV1

使用 SVT-AV1 编码，支持 10 位和高压缩效率。仅支持软件编码，在 macOS 上无硬件加速。

#### AV2（实验性）

使用随附的 AOM AVM 参考编码器（`avmenc`）进行实验性 AV2 编码，该功能最初在预览版本中推出。支持 8/10 位输出、恒定质量或可变码率模式，以及可配置的速度和分辨率。在恒定质量模式下，可分段并行编码以利用多个 CPU 核心。

可选择纯视频 IVF（`.ivf`）或带有 AAC / Opus 音频的 Matroska（`.mkv`）。参考编码非常慢，仍在演进的码流需要兼容 AV2 的解码器。应用可以解码 AV2 文件进行转换和生成缩略图，但尚不支持交互式播放。AV2 适合实验，不适合作为交付格式。

#### TV (HEVC 10-bit 4:2:2)

广播交付格式，采用硬件 HEVC 10 位 4:2:2 编码，支持设置分辨率和帧率、自动调整码率，并将所有音频通道保留为 24 位 PCM。

#### TV (AVC-Intra)

采用 MXF 容器的广播交付格式。AVC-Intra 10 位 4:2:2 支持选择 50/100/200 Mbps 等级、分辨率和帧率，并提供 4/8/16 个 24 位 PCM 单声道音频通道。

#### Stream copy

将现有音视频流复制到新文件，保留原始编码、元数据和扩展名，适合修剪和合并任务。

#### ProRes

采用 Apple ProRes（yuv422p10）生成便于剪辑的母版。包含第一个视频流和音频流，保留 24 位 PCM 音频，并使用标准 ProRes 码率。可在预设设置中选择默认 ProRes 配置。

#### Proxy

生成轻量的 HEVC、ProRes Proxy 或 DNxHR 代理文件，支持设置分辨率上限。所有音频通道均保留为未压缩 PCM，适合离线剪辑，并可使用源素材旁的独立 Proxy 子文件夹。

#### DCP (Digital Cinema Package)

导出符合 SMPTE 标准的数字电影包。将 BT.709 输入转换为 12 位 XYZ 色彩空间并编码为 JPEG 2000，使用 asdcp-wrap 封装为 MXF，并生成所需的 SMPTE XML 文件（CPL、PKL、ASSETMAP、VOLINDEX）。支持 2K 和 4K 的 Flat、Scope、Full 规格，帧率为 24/25/30/48 fps，码率可设为 100–250 Mbps。音频以 24 位 PCM 导出至独立 MXF 轨道。每项素材的元数据可编辑内容标题、类型、注释、分级和音频语言。缩放模式包括适应画面（加黑边）和填满画面（裁剪）。

#### IMF App 2e / RDD 45（实验性）

实验性的 IMF 包导出，包含一个图像轨道和一个 PCM 音频轨道。不支持包内字幕或多个音频轨道。用于交付之前，请在目标母版制作或交付工具中验证每个包。

#### Image Sequence

导入和导出 PNG、JPEG、TIFF、EXR、DPX、BMP、TGA、SGI、JPEG XL 和 JPEG 2000 图像序列。导入时自动检测帧编号，并允许编号缺失。可关联音频文件用于播放和导出。帧率可按序列设置，也可根据关联音频的时长自动计算。导出时可生成独立的元数据文件（Markdown 或 JSON），记录色彩空间、编码和相机信息。

#### Animated Stills

生成 GIF、AVIF 或动画 PNG（APNG）图像序列，可在预设设置中选择。

#### Audio Only AAC

下混为立体声 AAC，保留立体声声场并显著减小文件大小。

#### Audio Only WAV

导出未压缩 WAV，尽可能保留所有音频通道。

#### 10 个自定义 FFmpeg 预设

十个自定义预设（C1–C10）允许设置输出参数、文件名后缀和扩展名。输入参数由应用自动处理。使用 `-copy` 的路径不能与预设设置中的画面裁剪或音频重分配选项组合使用。

#### [待办事项 / 已知问题](../../TODO.md)

---

## 截图

#### 分组时间线视图

在片段列表旁预览序列，显示缩略图、音频波形、修剪手柄和输出时间码。时间线还提供分割、标记、范围选择和缩放控件。

![分组时间线视图](../screenshots/group-timeline.jpeg)

#### 时长修剪视图

![时长修剪视图](https://github.com/user-attachments/assets/0a48088d-e770-402a-a989-dc93d9fcb2c8)

#### 画面裁剪视图

![画面裁剪视图](https://github.com/user-attachments/assets/97745a95-7bda-43bf-873a-bd865e886690)

#### 音频重分配

![音频重分配](https://github.com/user-attachments/assets/b7f0ab61-a6f1-4f90-8ec6-2f90b05c6022)

#### 下载视图

![下载视图](https://github.com/user-attachments/assets/b2704580-464a-473d-9cac-9f1991ba4bb5)

#### 元数据视图

![元数据视图](https://github.com/user-attachments/assets/77f2c209-bc92-4cca-8e6c-36414bb0ecf3)

#### 时间码覆盖视图

![时间码覆盖视图](https://github.com/user-attachments/assets/7c3d951d-9bbb-402c-9984-2fe46fa7d713)

#### 设置视图

![设置视图](https://github.com/user-attachments/assets/26b71bfa-e947-42c8-bc0c-4e3e66e81099)

#### 全屏播放器

![全屏播放器](https://github.com/user-attachments/assets/c9af806f-279e-4a1c-a2ee-a4cae8572911)

---

## 系统要求

| | 最低要求 |
|---|---|
| macOS | 15.0（Sequoia）或更高版本 |
| 硬件 | Apple Silicon（M1 或更新型号） |

---

## 使用方法

1. 启动应用。
2. 将视频文件拖入窗口，或点击加号按钮导入文件。
3. 从工具栏菜单选择**导出预设**。
4. 点击绿色的 *Convert* 按钮，或按 ⌘⏎。

这是一个在业余时间开发的个人项目，我不会因此获得报酬。

---

## 许可证

本项目采用 **GNU General Public License，版本 3.0** 发布。完整文本见 [LICENSE](../../LICENSE)。

随附的 FFmpeg 二进制文件使用 `--enable-gpl` 编译，因此采用 **GPL v2 或更高版本**。本项目的全部代码采用 GPL v3，满足该要求。请参阅 [FFmpeg 原始许可证](../../Licenses/ffmpeg-LICENSE.txt)。

随附的 asdcp-wrap 二进制文件来自 John Hurst 的 [asdcplib](https://github.com/cinecert/asdcplib)，采用 **BSD 3-Clause License**。请参阅 [asdcplib 许可证](../../Licenses/asdcplib-LICENSE.txt)。

---

## 致谢

DCP 导出功能的色彩处理参考了 [DCP-o-matic](https://dcpomatic.com/) 项目关于 DCI XYZ 色彩空间转换的优秀文档。DCP-o-matic 是免费、开源的 DCP 制作工具：[GitHub 项目](https://github.com/cth103/dcpomatic)。

元数据检查和 C2PA 内容真实性功能由 [SwiftMediaMetadata](https://github.com/aagedal/SwiftMediaMetadata) 提供支持。

---

附注：此应用曾名为 Aagedal VideoLoop Converter。Aagedal Media Converter 是同一款应用，只是新名称更能体现它现在的功能。
