# AirCard

AirCard 是用于在 iPhone 本机自定义 Apple 钱包卡面的简体中文应用，利用 AirTraffic 修改卡面图片，并提供卡片管理、原始卡面备份与恢复，以及可编辑的卡面资源库。

本项目基于 [Mak5er/AirCard-iOS](https://github.com/Mak5er/AirCard-iOS) 修改，并参考上游的设备连接与钱包日志扫描逻辑。保留原项目的 SwiftUI 界面与 Rust 核心架构，在此基础上调整功能、交互和中文文案。感谢上游作者的工作；许可证与原作者版权声明见 [LICENSE](LICENSE)。

## 功能

### 配对与连接

- 关于页面展示应用简介、当前仓库和上游项目来源。
- 支持简体中文与英文界面；未手动选择语言时，系统首选语言为中文则默认中文，其他语言默认英文，手动选择会保存并优先使用。
- 支持配对文件导入和配对配置管理。
- 显示网络与 VPN 状态，提供内置回环 VPN 开关，也可以使用 LocalDevVPN 等外部回环 VPN。
- 网络状态支持识别内置和外部回环 VPN。
- 内置 VPN 配置名称为“AirCard VPN”。
- 活动日志支持本地时间格式、滚动查看、复制和清空。

### 钱包卡片

- 通过设备日志扫描钱包卡片 ID，每次扫描在开始后 120 秒自动停止，也支持手动停止。
- 支持原始卡面预览，以及从相册、文件或卡面资源库选择自定义卡面。
- 支持原始卡面备份与恢复。
- 支持勾选卡片，批量设置卡面、移除所选卡片或恢复所选卡片。
- 支持卡片重命名和备注保存。
- 支持应用内卡片排序。
- 支持清除已选图片、移除卡片和移除并恢复卡片；仅移除保留原始备份与备注，移除并恢复成功后清除该卡片的全部本地数据。

### 卡面资源库

- 支持卡面设计的创建、编辑、保存和删除。
- 设计页提供可展开和收起的图层调整面板。
- 从相册或文件添加封面和 Logo，内置银行、交通卡、卡组织和 Apple 标识。银行素材包含中国银行、农业银行、交通银行、民生银行、邮储银行、建设银行、浦发银行和光大银行；交通素材包含交通联合、岭南通、羊城通、广佛通、北京一卡通、上海交通卡和厦门 e通卡。素材清单见 [CardMaterialsSources.json](ios-app/CardMaterialsSources.json)。
- 支持添加最多 30 字符的自定义文字图层。
- 支持 Logo 和文字图层的位置、大小、旋转角度与透明度调整，以及图层排序、对齐辅助线和吸附。
- 图层列表支持左右滚动和拖放排序，内置素材提供独立缩略图预览。
- 文字图层支持粗体与斜体，独立于系统“粗体文本”设置，样式随工程保存。
- 支持导入 TTF、OTF 字体，所有设计共用字体库，文字图层可独立更换字体；支持删除导入字体，字体缺失时回退到默认字体。
- 文字图层支持双击切换调色模式、HSV 选色、六位十六进制色值、常用色及自定义颜色保存与删除，颜色随工程保存。

## 使用条件

- 工程最低部署版本为 iOS 18.0；具体系统和设备的扫描、写入与显示兼容性需要实际验证。
- 需要设备配对文件，可在电脑上使用 jitterbugpair 等工具生成，再导入手机。
- 设备连接通常需要回环 VPN。内置 VPN 扩展需要签名与描述文件授权 `packet-tunnel-provider`，主应用和扩展的标识、权限及签名须匹配；不能启用时可使用外部回环 VPN。
- 使用证书签名安装时，主应用及 VPN 扩展的 Bundle ID 必须匹配各自描述文件授权的 App ID，签名证书也须包含在对应描述文件中。

## 构建

项目使用 SwiftUI、NetworkExtension 和 Rust，Xcode 工程由 XcodeGen 根据 `project.yml` 生成。完整 IPA 构建需要 macOS 与 Xcode，当前 GitHub Actions 使用 macOS 15 和 Xcode 16.4。

在准备好 Xcode、XcodeGen 和 Rust 的 macOS 环境中执行：

```bash
bash build-ios.sh
bash build-ipa.sh
```

`build-ios.sh` 生成 Rust 的 `AirliftFFI.xcframework`，`build-ipa.sh` 构建并打包 `build/AirCard-iOS.ipa`。应用显示名称为 AirCard，工程、scheme 和产物内部名称仍为 AirCard-iOS。生成的 IPA 需要使用有效证书和描述文件重新签名后安装。

也可以在 GitHub 的 **Actions → Build Simplified Chinese IPA → Run workflow** 手动构建。

## 目录

| 目录／文件 | 用途 |
| --- | --- |
| `ios-app/` | SwiftUI 界面、配对、卡片管理、备份恢复与卡面编辑 |
| `loopback-vpn/` | 回环 VPN 扩展与数据包处理 |
| `rust-core/` | 设备连接、日志读取和 AirTraffic 文件操作 |
| `tests/` | 核心逻辑检查与测试源码 |
| `project.yml` | XcodeGen 工程配置 |
| `.github/workflows/build-ipa.yml` | 手动 IPA 构建工作流 |
