# 插件 README 标准模板

所有 dsh 插件（`@uachar/*`）的 README 必须按以下结构编写，块顺序固定，语言可中英双语
（`README.md` 英文 / `README.zh.md` 中文）。拷贝本模板，把 `<...>` 占位符替换为实际内容。

```markdown
# <包名>（<中文名，可选>）

<一句话简介：是什么、给 DeepSeek Harness 提供什么能力>

## 插件功能

- <功能点 1：做什么、触发条件/时机>
- <功能点 2>
- <特殊实现说明，如"零音频文件 / 纯 Web Audio 合成">

## 如何使用

<面向用户的操作步骤：入口在哪、怎么配置、注意事项>

## 安装与卸载

> 需要可用的 `dsh` CLI（pnpm）与一个 profile，例如 `web`。

### 从 npm 安装（推荐）

```sh
pnpm dsh plugin --profile web add <npm 包名>
```

### 从 GitHub Release tarball 安装

```sh
pnpm dsh plugin --profile web add <release tarball URL>
```

### 从源码构建并安装

```sh
git clone <仓库 URL>.git
cd <目录>
pnpm install
<构建命令，如 pnpm run build；如有额外构建步骤（tsc/tsdown/typert）逐条列出>
pnpm dsh plugin --profile web add link:<本目录的绝对路径>
```

安装后**重启 dsh** 生效。

### 卸载

```sh
pnpm dsh plugin --profile web remove <npm 包名>
```

随后重启 dsh。（如需说明面板卸载的额外清理行为，在此补充。）

## 项目文件结构

| 文件 | 作用 |
|---|---|
| `<文件路径>` | <作用> |

## 使用限制

- <限制 1>

## 许可

MIT
```

## 编写要点

1. **插件名**：用 npm 包名（标题），可附中文名。
2. **插件功能**：写"做什么 + 何时触发"，而不是"技术栈"。
3. **如何使用**：从用户视角写；必要时放截图（图片存 `docs/` 目录，用相对路径引用）。
4. **安装**：npm 方式必须放在第一位（社区标准发布渠道）；tarball 与源码构建依次排列；构建命令要与实际一致。
5. **项目文件结构**：表格式，按"宿主侧 / 浏览器侧 / 补丁 / 产物"分组说明职责。
6. **使用限制**：没有则写"无"或省略该块。
7. **许可**：与 package.json 的 `license` 字段一致。
