# Bssist

基于 SwiftUI 与 Liquid Glass 视觉设计的 macOS 13+ 原生哔哩哔哩视频下载器。

## 功能特性
- **Liquid Glass 极简界面**：全简体中文界面，调用原生 `GlassEffectContainer` / `.glassEffect` 液态玻璃卡片与交互按钮，采用 Shadowrocket 分组式布局。
- **最高支持 8K / 杜比视界 / HDR / 4K / 1080P60**：内置 WBI 签名与客户端扫码登录（自动维护 `buvid3` 与 `SESSDATA` 凭据）。
- **多路分片并发加速**：10 路 HTTP `Range` 分片并发、多 CDN 镜像条带化轮询（优先官方 `upos-*` 节点）与无锁 POSIX `pwrite` 磁盘直写。
- **分片级断点暂停与恢复**：支持单任务及全局暂停/继续，精确记录已完成的 `2 MB` 分片，恢复时零重复下载。
- **零外部依赖无损混流**：基于 macOS 原生 `AVFoundation` 直通合成 `.mp4`（含 4K/8K HEVC `hev1` 至 `hvc1` 头部修正）。

## 构建与运行

```bash
./build_app.sh
open Bssist.app
```
