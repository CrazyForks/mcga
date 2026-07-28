# AGENTS.md

This file provides guidance to Codex when working with this repository.

## 项目简介

mcga（My Clipboard Guard Assistant）是 macOS-only 剪切板智能解析工具。App 常驻菜单栏，监控剪切板变化，统一执行解析器并展示当前结果和历史结果。

## 常用命令

所有 shell 命令先加载用户 zsh 环境：

```bash
source ~/.zshrc && <command>
```

```bash
source ~/.zshrc && swift run MCGASmokeTests
source ~/.zshrc && swift build --product MCGA
source ~/.zshrc && bash scripts/build-macos-app.sh
source ~/.zshrc && open .build/MCGA.app
source ~/.zshrc && pkill MCGA
```

## 重新安装

修改后重新安装 MCGA 时，必须完整执行构建、替换 App、重置辅助功能权限和重启流程，不要只打开 `.build/MCGA.app`：

```bash
source ~/.zshrc
cd macos
bash scripts/build-macos-app.sh
pkill MCGA || true
if [[ -d /Applications/MCGA.app ]]; then
  mv /Applications/MCGA.app "/Users/jimyag/.Trash/MCGA-previous-$(date +%Y%m%d-%H%M%S).app"
fi
ditto .build/MCGA.app /Applications/MCGA.app
codesign --verify --strict --verbose=2 /Applications/MCGA.app
tccutil reset Accessibility com.jimyag.mcga
open /Applications/MCGA.app
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

重置后需要在“系统设置 > 隐私与安全性 > 辅助功能”中重新启用 `MCGA.app`。

## 架构概览

```
Package.swift
Sources/MCGA/MCGAApp.swift       状态栏 App、剪切板轮询、Popover、自动浮层、设置窗口
Sources/MCGACore/ParserEngine.swift
Sources/MCGACore/*Parsers.swift  内置解析器实现
Sources/MCGACore/CustomCommandParser.swift 自定义 command 解析器
Sources/MCGACore/HistoryStore.swift
Sources/MCGASmokeTests/main.swift 无 XCTest 依赖的 smoke test
Packaging/Info.plist             .app bundle 元数据，LSUIElement=true
scripts/build-macos-app.sh       打包 .build/MCGA.app
```

## 解析器注册顺序

`Sources/MCGACore/ParserEngine.swift` 中解析器顺序决定 `parse()` 的优先级，越具体的解析器越靠前。

当前 Swift 版覆盖：关键词生成器、自定义 command 解析器、CIDR、UUID、ObjectID、Hash、IPv6、公网 IPv4、Timestamp、HTTP Status、Number Base、Cron、URL、JSON、JSON5、XML、TOML、YAML、HTML Entity、Unicode Escape、Base64、DNS。

## 自定义 Command 解析器

自定义解析器配置文件：

```text
~/.config/mcga/custom_parsers.json
```

只支持 `kind: "command"`。App 会把剪切板内容写入命令 stdin，并读取 stdout：

- exit code 为 `0` 且 stdout 非空时才产生解析结果
- stdout 第一行作为结果正文
- stdout 多行时完整 stdout 作为详情
- stderr 忽略
- `command` 支持绝对路径、`~`、`$HOME`、`${HOME}`
- 命令必须是可执行文件
- `timeoutMs` 范围 50-3000 ms，默认 500 ms
- 可选 `match` 正则用于运行命令前过滤剪切板内容

## 运行时行为

Swift App 打开后常驻菜单栏，不出现在 Dock。复制可解析内容时会自动弹出浮层，同时状态栏 Popover 可查看当前结果和历史。历史记录按操作时间排序：新复制内容、从历史复制、从历史粘贴都会把对应记录移动到第一位，单纯选中和键盘移动不改变顺序。浮层内复制解析结果时要避免再次触发自解析。
