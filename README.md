# DSH Web 一键部署

当前版本：**1.0.0**

## 这个整合包是干什么的

一句话：**双击一次，在你的 Windows 电脑上装出一个独立的 DeepSeek Harness 网页端，并自动装好 `dsh-purge-plus`（破甲）插件。**

装完之后你会得到：

- 一个在浏览器里打开的 DSH（默认地址 `http://127.0.0.1:18760`），可以和桌面版 DSH 同时开着，互不干扰
- 完全独立的程序目录和数据目录：桌面版的会话、设置、登录状态、提示词一个都不动
- 已经打好宿主补丁的 `dsh-purge-plus`，`无限制模式`、`红队模式` 两个预设装完即可用
- 桌面上一枚带 DSH 官方图标的 **DSH Web** 快捷方式
- 配套的 `update.cmd`（跟进 DSH 与插件上游更新）和 `uninstall.cmd`（一键删干净）

它**不包含**：DSH 本体二进制、任何账号、API Key、会话记录或提示词内容。DSH 由脚本从官方地址或公开镜像现场下载原版安装包并解包；破甲插件从上游 GitHub 仓库现场拉取。

**适合**：想在不影响现有桌面版 DSH 的前提下，单独跑一个可以自由改提示词、关闭审批与沙箱的测试环境的人。

**不适合**：把它当生产工具、或需要审批保护兜底的人——装好之后 DSH 的审批弹窗和沙箱基本是关着的，详见文末「风险提示」。

> 非官方项目。DSH 是 DeepSeek 的软件，`dsh-purge-plus` 是第三方开源插件（MIT，上游 `luowang-ui/dsh-purge-plus`）。本仓库与两者均无隶属或背书关系。

## 一键安装

1. 解压/克隆本仓库到任意目录。
2. 双击 `install.cmd`。
3. 等待安装完成，桌面会出现带 DSH 官方图标的 **DSH Web** 快捷方式。
4. 双击该快捷方式启动网页端。

安装脚本会：

- 测速两个下载通道，选择较快的通道下载 DSH 安装包
- 校验 SHA512
- 把 DSH 解包到 `%LOCALAPPDATA%\DSH-Web\app`
- 创建完全独立的数据目录 `%LOCALAPPDATA%\DSH-Web\home`
- 安装 `dsh-purge-plus` 并应用宿主补丁
- 创建带 DSH 官方图标的桌面快捷方式

## 安装进度

安装脚本会显示：

- `[n/9] 进度 x%` 和当前步骤已用时间
- 两个下载通道的实测速度
- DSH 下载预计时间和总安装预计时间（通常约 3–8 分钟，取决于网速）
- 每一步完成后的累计耗时

下载阶段会显示 curl 的进度条和百分比。

## 一键卸载

双击 `uninstall.cmd`。

卸载只会删除 `%LOCALAPPDATA%\DSH-Web` 和对应的桌面快捷方式，不会修改桌面版 DSH 或 `~/.dsh`。

## 更新 DSH 或破甲插件

双击 `update.cmd`。

更新脚本会：

1. 停止当前网页端
2. 读取 DSH 官方 `nightly.yml` 的最新版本和 SHA512
3. 查询 `dsh-purge-plus` 最新 commit
4. 把当前 `app` 和 `plugins-src` 重命名为 `app.bak-时间`、`plugins-src.bak-时间`
5. 重新下载、解包、安装插件、应用补丁
6. 如果新版本的锚点不兼容，自动恢复旧 `app` 和旧插件目录
7. 启动网页端

**用户数据 `home` 不会被覆盖**：会话、设置、登录状态和提示词都保留。

也可以手动指定版本：

```powershell
.\update.ps1 -DshVersion "0.2.2-rc.1" -ExpectedSha512 "<对应的 SHA512>"
```

> DSH 是预发布软件，更新后宿主锚点可能变化。更新失败时脚本不会假装成功，会恢复旧版本；旧版本备份目录会保留，确认无误后可手动删除。

## 自定义参数

在 PowerShell 中运行：

```powershell
.\install.ps1 -InstallRoot "D:\Tools\DSH-Web" -Port 18760
```

常用参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-InstallRoot` | `%LOCALAPPDATA%\DSH-Web` | 独立安装目录 |
| `-Port` | `18760` | 网页端端口 |
| `-DshVersion` | `0.2.2-rc.1` | 下载的 DSH 版本 |
| `-InstallerPath` | 空 | 使用本地已下载的 DSH 安装包 |
| `-NoStart` | 关闭 | 安装完成后不自动启动网页端 |
| `-Force` | 关闭 | 允许覆盖已有安装目录 |

> 修改 `-DshVersion` 时，默认 SHA512 不再适用，需要同时传入对应的 `-ExpectedSha512`，或者传空字符串跳过校验。

## 隔离说明

- 已装好的桌面版 DSH：保持它自己的安装目录 + `%USERPROFILE%\.dsh`，不做任何改动
- 网页版 DSH：`%LOCALAPPDATA%\DSH-Web\app` + `%LOCALAPPDATA%\DSH-Web\home`
- 两者使用不同程序目录、数据目录和端口
- 安装包不包含任何账号、API Key、会话、日志或提示词内容

## 下载通道

安装脚本内置两个 DSH 0.2.2-rc.1 下载地址：

- DeepSeek 官方：`download.deepseek.com`
- 社区 GitHub 镜像：`LinJianKun/deepseek-harness-desktop-mirror`

脚本会先探测速度，再使用较快的通道。镜像为第三方非官方镜像，正式使用建议优先官方通道。

## 安全与内容清理

- 安装脚本会排除插件自带的 `skills/redteam` 技能库。该目录包含 Webshell/后门示例，Windows Defender 曾将其中 `unauth-exploit.md` 判定为 `Backdoor:PHP/Chopper.E!dha`。
- 本仓库不包含任何提示词正文、会话、账号、API Key 或用户配置。
- 核心破甲（提示词注入、宿主补丁、审批/沙箱放行）和 `unrestricted` 预设不受影响；红队技能库需要自行评估后再安装。

## 风险提示

- `dsh-purge-plus` 会移除 DSH 的审批弹窗、沙箱和部分工具限制。
- 只在**你自己的机器**或**明确授权的测试环境**中使用。
- 不要把它用于未授权的网络攻击、入侵或数据破坏。
- 本项目与 DeepSeek、DSH 官方、`dsh-purge-plus` 作者均无隶属关系。
- 预发布版本和插件兼容性可能随上游更新而变化。
