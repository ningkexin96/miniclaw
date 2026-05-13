# Miniclaw

基于 Pi Agent Runtime 的自托管 AI Agent 工作台，连接 Web、消息渠道、Workspace、Memory、Skills、MCP、Subagents 与自动化任务。

Miniclaw 把长期运行的 Agent、工作区、会话、权限和渠道接入组织在同一个多用户服务中。Agent 由 Pi Runtime 驱动，可以读写项目文件、使用工具、加载 Skills、调用 MCP，并在宿主机或 Docker 隔离环境中执行任务。

## 核心能力

- Pi Agent Runtime：Pi Coding Agent、Tools、Extensions 与 Subagents。
- Workspace 与 Session：文件、执行环境、会话上下文和渠道绑定分层隔离。
- Memory：按 Workspace 管理可搜索、可修订的事实、决策和经验。
- Skills 与 MCP：内置、项目、用户和插件能力统一治理。
- Multi-channel：飞书、Telegram、QQ、钉钉、微信、Discord、WhatsApp。
- Scheduler：Cron、间隔和一次性任务，支持运行历史、通知与恢复。
- Docker：为普通成员和需要隔离的工作区提供容器执行环境。
- Electron Desktop：在桌面窗口中承载现有 Web Client，Main/Preload 负责窗口生命周期与安全 IPC。

## 智能体优先工作模型

Miniclaw 使用 `Agent → Workspace → Runtime Session` 的层级模型：Agent 保存身份与能力策略，Workspace 管理文件和执行边界，Session 保存独立对话上下文。下图展示客户端、Backend、渠道和 Pi Runtime 的关系。

## 架构

```text
Miniclaw
│
├── Web Client
│
├── Electron Desktop
│   ├── Main Process
│   ├── Preload
│   └── React Renderer (existing Web Client)
│
├── Miniclaw Backend
│
├── Workspace
├── Session
├── Memory
├── Scheduler
├── Channel
│
└── Pi Agent Runtime
        │
        ├── Pi Coding Agent
        ├── Skills
        ├── Tools
        ├── Extensions
        └── Subagents
```

Web Browser 和 Electron Desktop 都通过 HTTP/WebSocket 连接 Miniclaw Backend。Electron 只是 Desktop Shell：SQLite、filesystem、Pi Runtime、Docker、credentials 和 shell/process 操作不会进入 Renderer；需要本机权限的桌面能力只通过受限 Preload IPC 暴露。

## 快速开始

环境要求：Node.js 20+、npm、GNU Make；Container 工作区还需要 Docker。

```bash
git clone https://github.com/helsome/miniclaw.git
cd miniclaw
npm install
npm --prefix web install
npm --prefix container/agent-runner install
npm run build:all
npm start
```

默认服务地址是 <http://127.0.0.1:3000>。开发时可以使用：

```bash
npm run dev:all
```

首次启动后，按 Web 页面完成管理员初始化和 Provider 配置。Agent 容器镜像默认使用 `helsome/miniclaw-agent:latest`，也可以通过 `MINICLAW_CONTAINER_IMAGE` 或 `CONTAINER_IMAGE` 覆盖。

## Electron Desktop

Desktop Shell 默认连接 `http://127.0.0.1:3000`。先启动 Miniclaw Backend，再运行：

```bash
npm run desktop:typecheck
npm run desktop:build
npm run desktop:dev
```

连接其他 Backend：

```bash
MINICLAW_SERVER_URL=https://your-miniclaw.example.com npm run desktop:dev
```

开发时如果要直接连接 Vite Web Client，可使用 `MINICLAW_RENDERER_URL=http://127.0.0.1:5173`；Vite 会把 `/api` 和 `/ws` 代理到 `http://127.0.0.1:3000`。桌面打包命令：

```bash
npm run desktop:package:dir
npm run desktop:package
```

打包配置位于 [`electron/electron-builder.yml`](electron/electron-builder.yml)。发布前请为目标平台准备签名和分发配置。

## 执行与安全边界

主服务始终由 Node.js 运行，负责认证、API、WebSocket、队列、调度、渠道连接、Provider、用量和 SQLite 持久化。Docker 只隔离 Agent 执行环境，不承载 Desktop UI。

Electron BrowserWindow 使用 `contextIsolation`、关闭 `nodeIntegration` 和 sandbox。Renderer 不会直接读取文件、数据库或凭据；外部链接由 Main Process 校验协议后打开。远程桌面连接建议使用 HTTPS/WSS，并避免把访问凭据写入命令行历史。

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `npm run dev:all` | 启动 Backend 与 Web Client |
| `npm run build:all` | 构建 Backend、Web Client 与 Agent Runner |
| `npm test -- --run` | 运行测试 |
| `npm run typecheck` | 检查 Backend 类型 |
| `npm run desktop:typecheck` | 检查 Electron Main/Preload 类型 |
| `npm run desktop:package` | 构建并打包桌面应用 |
| `make backup` | 创建运行时数据备份 |
| `make restore FILE=...` | 恢复指定备份 |
| `make stop` | 停止当前端口上的服务 |

## 文档

- [API](docs/API.md)
- [ACL Matrix](docs/ACL-MATRIX.md)
- [Runtime migration notes](docs/runtime-migration.md)
- [Brand cleanup record](docs/miniclaw-migration-cleanup.md)
- [Security policy](SECURITY.md)

## 贡献

提交前至少运行：

```bash
npm run typecheck
npm run desktop:typecheck
npm test -- --run
npm run build:all
```

请保持 Backend、Web Client、Electron Shell 和 Pi Agent Runtime 的边界清晰。新桌面能力应优先放在 Main/Preload；不要在 Renderer 中引入 SQLite、filesystem、credentials、Docker 或 shell/process 访问。

## License

Miniclaw 使用 MIT License，详见 [LICENSE](LICENSE)。
