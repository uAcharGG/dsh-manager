# dsh-launcher — DeepSeek Harness 管理面板

DeepSeek Harness（`dsh web`）的一键本地启动器与管理面板。双击即可启动 harness，随后在浏览器里管理：启动/停止/重启服务、安装/卸载/启停插件、查看实时日志、用原生对话框选择插件文件夹。

面板后端是单文件 PowerShell HTTP 服务（`web-manager/server.ps1`）——无需 Node、无需数据库，除 Windows 自带能力外零依赖。

## 功能特性

- **一键服务控制** — 启动/停止/重启本地 `dsh web`（默认端口 3080），带就绪检测与自动打开浏览器。
- **插件管理** — 通过后台 `dsh plugin`（pnpm）对 profile 组合层执行安装/卸载/启停，日志区实时显示进度。
- **运行中保护** — dsh 运行中禁止安装/卸载插件：组合层变更需重启才生效，面板会提示先停止服务。
- **原生文件夹选择** — 文件夹图标在独立进程中打开 Windows 文件夹对话框（无黑窗、不阻塞服务器），所选路径自动填入"本地路径"输入框。
- **插件来源显示** — 每个已装插件显示从 README 提取的功能描述（无则显示 `-`）与真实文件来源路径（由 `link:`/`file:` 依赖解析）；内置组合包显示"内置模板组合包"。
- **实时日志** — 启动日志与插件操作日志增量推送到页面。

## 快速开始

1. 双击 **`dsh-manager.cmd`**（或直接运行 `web-manager/server.ps1`）。
2. 面板地址 `http://127.0.0.1:3399`，dsh 服务地址 `http://127.0.0.1:3080`。
3. 「一键启动」页启动服务，「插件管理」页管理插件。

> 端口：管理面板默认 **3399**（占用时自动回退），dsh 默认 **3080**。dsh 源码目录默认 `D:\AI\DeepSeekHarness\deepseek-harness`，可用 `-Checkout` 参数指定。

## 插件操作流程

- **安装本地插件**：先停止服务 → 点文件夹图标选择插件目录 → 点「安装」→ 重新启动服务。
- **npm / git / tarball 安装**：选择来源类型、输入 spec、点「安装」（同样需先停止服务）。
- **卸载 / 启停**：先停止服务，再卸载或切换开关；重启后生效。
- 操作在后台 job 中执行，进度见插件日志，完成后列表自动刷新。

## HTTP API

| 接口 | 方法 | 用途 |
|---|---|---|
| `/api/status` | GET | 运行状态、地址、插件操作忙碌标记 |
| `/api/profiles` | GET | 可用 profile（`web`、`headless`） |
| `/api/plugins?profile=` | GET | 已装插件（版本、README 描述、来源路径） |
| `/api/logs?log=launch\|plugin&cursor=` | GET | 增量日志 |
| `/api/start` / `/api/stop` / `/api/restart` | POST | 服务控制 |
| `/api/plugins/install` / `uninstall` / `toggle` | POST | 插件操作（dsh 运行中禁止安装/卸载） |
| `/api/pick-directory` / `pick-directory-result` | POST / GET | 原生文件夹选择（分离进程弹框 + 结果轮询） |

## 目录结构

```
dsh-launcher/
├── dsh-manager.cmd / .ps1   # 启动入口
├── start-dsh.cmd / .ps1     # 仅启动服务
├── build-icons.mjs          # 图标构建辅助
├── assets/                  # 面板图标
└── web-manager/
    ├── server.ps1           # 整个后端（HTTP 服务 + 全部动作）
    ├── app.js               # 前端逻辑
    ├── index.html           # 面板界面
    └── cleanup.cmd / .ps1   # 清理辅助
```

## 技术说明

- 后端是 `TcpListener` 最小 HTTP 实现——不依赖 `http.sys`、无需管理员 URL ACL，兼容 Windows PowerShell 5.1 与 PowerShell 7+。
- 文件夹对话框运行在**分离的隐藏控制台 PowerShell 进程**中，单线程 HTTP 循环永不阻塞，前端轮询结果。
- 停止服务会收集全部相关进程（端口监听 + 命令行匹配 + 父进程链）并整树结束。

## 许可

MIT
