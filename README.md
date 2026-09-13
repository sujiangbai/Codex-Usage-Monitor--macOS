# Codex Usage Monitor

<img src="Resources/AppIcon.png" alt="Codex Usage Monitor icon" width="96">

独立开发的 macOS Codex 额度菜单栏工具。

原生 SwiftUI / AppKit 小应用：菜单栏显示细进度环与剩余百分比。点击后可选择「每周」或「5 小时」，选择会保存。首次打开时由用户选择是否登录 Mac 后自动启动，之后可以在面板中切换。

## 下载与安装

从 [GitHub Releases](https://github.com/sujiangbai/Codex-Usage-Monitor--macOS/releases) 下载 `Codex-Usage-Monitor-v0.1.0-macOS-arm64.zip`，解压后将应用放入 `~/Applications`（推荐）或 `/Applications`，再打开。更新前先退出旧版。当前支持 Apple Silicon Mac 和 macOS 13+，不提供 Intel 构建。

发布包使用 ad-hoc 签名，**尚未经过 Apple Developer ID 签名及公证**，macOS 可能阻止打开下载的应用。也可以按照下方说明在自己的 Mac 上从源码构建。请勿为此关闭系统整体安全保护。

Release 同时提供 `SHA256SUMS.txt`，下载到与 ZIP 相同的目录后可校验文件完整性：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

## 使用

1. 保持官方 Codex 已安装并通过 ChatGPT 账号登录。
2. 打开 `~/Applications/Codex Usage Monitor.app`。
3. 点击菜单栏的圆环和百分比；选择显示周期。
4. 首次打开时点击「暂不开启」或「开启自动启动」。关闭面板不会替你作出选择；下次打开仍可选择。

自动启动使用 macOS 的 SMAppService 登录项。若 macOS 要求确认，应用会显示「打开登录项设置」。没有创建 LaunchAgent，没有修改 Codex 或 shell 启动脚本。退出组件不会退出 Codex。

面板固定从菜单栏下方展开，并限制在当前屏幕的可用区域内。刷新或切换内容时保持顶部位置；屏幕高度不足时可以滚动。点击其他窗口或按 Escape 可以收起面板。

界面采用浅色磨砂玻璃：334pt 宽、18pt 圆角、14pt 内边距。原生 NSVisualEffectView 使用浅色 HUD 材质、behindWindow 模糊和细微乳白高光，透出后方桌面或窗口；没有背景贴图。开启系统“减少透明度”后使用高不透明度底色，“减少动态效果”会关闭控件动画。

圆角外缘完全透明，键盘焦点使用中性灰轮廓。磨砂层单独调节透明度，文字与控件保持清晰。

右上角圆箭头用于刷新。常规状态将启动开关和退出放在同一行；首次启动使用独立引导区。菜单栏显示选择、双周期数据展示、低额度颜色提示、错误与登录项审批提示均保留。Tab 可移动焦点，空格或回车可激活当前按钮。

## 额度与刷新

- 启动时查询，之后每 5 分钟查询；支持手动刷新，Mac 唤醒后也会刷新。
- 默认优先每周；首次数据返回时 Plus 若有 5 小时额度则默认选中 5 小时。之后以用户的已保存选择为准。
- 按接口 `windowDurationMins` 识别周期，不将 primary / secondary 固定解释成 5 小时 / 每周。
- 优先使用 `rateLimitsByLimitId.codex`；不会把其他模型额度当成 Codex 主额度。
- 缺失、过期、查询失败或重置尚待确认时显示 `—`。未返回某周期不等于无限额度。
- 查询超过 25 秒会结束；查询进程在完成或退出组件时停止，不常驻额外 app-server。
- 无系统通知、无多账号、无余额购买、无额度重置功能。

## 隐私边界

组件仅调用本机官方 Codex 的 `initialize`、`initialized` 和 `account/rateLimits/read`，通过标准输入输出通信，没有开放网络监听端口。由官方进程管理既有认证并向 OpenAI 查询额度，组件不直接读取或复制任何凭据。

组件不读取聊天记录、项目内容或浏览器 Cookie，不进行模型推理，不发送消息，不收集遥测，不保存额度历史。只解码额度比例、窗口时长、重置时间和用于首次默认选择的订阅类型；账号 ID、积分、优惠或重置券等字段会被忽略。请求关闭重置券详情查询。

调用时以进程参数禁用 analytics 和 OpenTelemetry 的日志、追踪、指标导出，不修改用户的 Codex 配置。标准错误丢弃，应用不会保存原始响应或原始错误。官方 Codex 进程仍会按自身机制读取配置和认证，并可能维护它自己的运行状态；组件不会读取这些状态文件的内容。

应用仅通过 UserDefaults 保存 `displayPeriod` 和 `startupChoiceMade` 两项偏好。自启状态由 macOS 管理。首次启动不调用注册登录项；必须由用户点击开启。

## 构建与验证

需要 Apple Silicon Mac、macOS 13+ 和 Xcode Command Line Tools。无第三方依赖。

```sh
git clone https://github.com/sujiangbai/Codex-Usage-Monitor--macOS.git
cd Codex-Usage-Monitor--macOS
zsh build.sh
zsh test.sh
zsh install.sh
open "$HOME/Applications/Codex Usage Monitor.app"
```

`zsh test.sh --live` 会在用户已同意额度读取的前提下，通过官方 Codex 再查询一次真实额度。常规测试完全使用合成数据。

`build/Codex Usage Monitor.app/Contents/MacOS/CodexQuota --demo` 使用内存内示例数据，不联网、不保存设置。`--render-preview <目录>` 只绘制应用自己的示例界面，不截取用户屏幕。

`--verify-layout` 使用示例数据对实际原生窗口进行布局回归检查，验证不同内容高度时窗口仍在当前屏幕内，不读取账号或截取屏幕。常规测试还包括 60 组窗口定位边界检查。

`--demo --demo-weekly-only` 仅用于独立验证单周期首次启动状态；加 `--demo-regular` 可直接显示常规状态。`--demo-backdrop` 和可选的 `--dark-backdrop` 只在演示模式创建临时背景窗口，不修改壁纸。仓库不包含真实账号额度截图或运行记录。

构建使用本机 ad-hoc 签名，未进行 Developer ID 公证。建议在自己的 Mac 上从源码构建；当前没有提供经过公证的安装包。

维护者可在干净的 Git 工作区运行 `zsh scripts/release.sh`：脚本从当前提交导出源码、执行测试、重新构建，生成不含本地扩展属性的 ZIP 与校验文件，输出到 `build/releases/v<版本号>/`。它不会自动创建标签或上传到 GitHub。


## 图标资源

`Resources/AppIcon.icns` 包含 16–1024px 的应用图标；`AppIcon.png` 是透明 PNG 母版，`AppIconArtwork.png` 是生成式设计原稿。重新打包图标：

```sh
mkdir -p build/module-cache
xcrun swift -module-cache-path build/module-cache scripts/PackageIcon.swift Resources/AppIconArtwork.png build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
```

## 停用与删除

先在组件面板关闭「登录 Mac 时启动」，点击「退出」，再将 `~/Applications/Codex Usage Monitor.app` 移到废纸篓即可。偏好域为 `local.codexquota.menubar`；偏好只包含上述选择，不含额度和账号数据。

## 许可证

Copyright 2026 sujiangbai。

本项目采用 [Apache License 2.0](LICENSE)，署名信息见 [NOTICE](NOTICE)。允许商业使用、修改和再分发，不要求衍生项目公开源码；再分发时应遵守许可证与相关声明保留、修改标注等要求。许可证包含明确的专利授权条款，不授予商标使用权。

构建后的应用资源目录与后续发布的 ZIP 均附带 `LICENSE` 和 `NOTICE`。

## 参考

- [官方额度接口](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt)
- [Codex 隐私相关配置](https://learn.chatgpt.com/docs/config-file/config-reference)
- [macOS 登录项](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)
