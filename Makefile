.PHONY: dev dev-backend dev-web build build-backend build-web start \
       typecheck typecheck-backend typecheck-web typecheck-agent-runner \
       format format-check install install-host-tools clean reset-init update-pi-runtime update-sdk ensure-latest-pi-runtime ensure-latest-sdk sync-types \
       backup restore help _ensure-docker-image docker-pull logs status stop \
       _check-sync _ensure-builtin-skills _build-web-if-stale _build-ar-if-stale _build-backend-if-stale

# ─── Runtime ────────────────────────────────────────────────
# 本项目只用原生 Node 工具链运行（npm / npx / tsx / node），不使用 bun。
# 原因：主服务的 WebSocket 走 `ws` 包 + @hono/node-server 的 `server.on('upgrade')`
# 握手，该模式在 bun 的 HTTP server 下不触发，会导致 WS 全部握手失败（HTTP/接口正常，
# 但前端实时流式卡片/通知全失效，飞书等 stdout 通道不受影响）。
PORT    ?= $(or $(WEB_PORT),3000)
export WEB_PORT := $(PORT)
PKG     := npm
RUN     := npx
RUNNER  := npx tsx src/index.ts
RUNTIME_DATA_DIR ?= data
BACKUP_DIR ?= .
CONTAINER_IMAGE ?= ningkexin96/miniclaw-agent:latest
export CONTAINER_IMAGE

# ─── Development ─────────────────────────────────────────────

dev: ## 启动前后端（首次自动安装依赖并拉取容器镜像）
	@if [ ! -d node_modules ] || [ package.json -nt node_modules ] || [ package-lock.json -nt node_modules ] || [ web/package.json -nt web/node_modules ] || [ web/package-lock.json -nt web/node_modules ] || [ container/agent-runner/package.json -nt container/agent-runner/node_modules ] || [ container/agent-runner/package-lock.json -nt container/agent-runner/node_modules ]; then echo " Installing updated dependencies..."; $(MAKE) install; fi
	@$(MAKE) _ensure-builtin-skills
	@$(MAKE) _ensure-docker-image
	@$(PKG) --prefix container/agent-runner run build --silent 2>/dev/null || $(PKG) --prefix container/agent-runner run build
	@echo " Starting with $(PKG)..."
	$(PKG) run dev:all

dev-backend: ## 仅启动后端（tsx 直跑 TS）
	$(RUNNER)

dev-web: ## 仅启动前端
	cd web && $(PKG) run dev

# ─── Build ───────────────────────────────────────────────────

build: sync-types ## 编译前后端及 agent-runner
	$(PKG) run build:all
	@touch .build-sentinel

build-backend: ## 仅编译后端
	$(PKG) run build

build-web: ## 仅编译前端
	cd web && $(PKG) run build

# ─── Production ──────────────────────────────────────────────

start: ## 一键启动生产环境（前台阻塞运行）
	@# Production start must not implicitly rewrite the dependency graph; run make update-pi-runtime explicitly,
	@# and verify before committing package.json and lockfile.
	@# Check whether the port is in use
	@if lsof -ti:$(PORT) -sTCP:LISTEN >/dev/null 2>&1; then \
	  echo " Port $(PORT) is already in use; stop the old process first: make stop"; \
	  lsof -ti:$(PORT) -sTCP:LISTEN | xargs ps -fp 2>/dev/null | tail -1; \
	  exit 1; \
	fi
	@if [ ! -d node_modules ] || [ package.json -nt node_modules ] || [ package-lock.json -nt node_modules ] || [ web/package.json -nt web/node_modules ] || [ web/package-lock.json -nt web/node_modules ] || [ container/agent-runner/package.json -nt container/agent-runner/node_modules ] || [ container/agent-runner/package-lock.json -nt container/agent-runner/node_modules ]; then echo " Installing updated dependencies..."; $(MAKE) install; fi
	@$(MAKE) _ensure-builtin-skills
	@$(MAKE) _ensure-docker-image
	@$(MAKE) _check-sync
	@$(MAKE) _build-backend-if-stale
	@$(MAKE) _build-web-if-stale
	@$(MAKE) _build-ar-if-stale
	@echo " Node mode: running compiled dist/index.js (this project does not use bun; WebSocket needs node)"
	node dist/index.js

# ─── Internal build checks ────────────────────────────────────

_check-sync: ## (内部) 检测 shared/ 类型变更并同步
	@NEED_SYNC=0; \
	for target in src/stream-event.types.ts web/src/stream-event.types.ts container/agent-runner/src/stream-event.types.ts src/image-detector.ts container/agent-runner/src/image-detector.ts src/channel-prefixes.ts container/agent-runner/src/channel-prefixes.ts; do \
	  if [ ! -f "$$target" ] || [ -n "$$(find shared/ -newer "$$target" -name '*.ts' 2>/dev/null | head -1)" ]; then NEED_SYNC=1; break; fi; \
	done; \
	if [ "$$NEED_SYNC" = "1" ]; then echo " shared/ type changes detected, syncing types..."; $(MAKE) sync-types; fi

_ensure-builtin-skills: ## (内部) 物化固定版本、Host/Container 共用的内置 Skills
	@if ! node scripts/builtin-skill-catalog.mjs validate data/builtin-skills; then \
	  echo " Pinned builtin Skills missing, materializing..."; \
	  ./scripts/install-host-tools.sh skills; \
	else \
	  echo " builtin Skills catalog is ready"; \
	fi

_build-web-if-stale: ## (内部) 前端变更时重新编译
	@NEED_WEB=0; \
	if [ ! -f web/dist/index.html ]; then NEED_WEB=1; \
	else \
	  for f in web/package.json web/vite.config.ts web/index.html web/tsconfig.json; do \
	    if [ -f "$$f" ] && [ "$$f" -nt web/dist/index.html ]; then NEED_WEB=1; break; fi; \
	  done; \
	  if [ "$$NEED_WEB" = "0" ] && [ -n "$$(find web/src/ web/public/ -type f -newer web/dist/index.html 2>/dev/null | head -1)" ]; then NEED_WEB=1; fi; \
	fi; \
	if [ "$$NEED_WEB" = "1" ]; then echo " Frontend changes detected, rebuilding..."; cd web && $(PKG) run build; else echo " Frontend unchanged, skipping build"; fi

_build-ar-if-stale: ## (内部) agent-runner 变更时重新编译
	@NEED_AR=0; \
	if [ ! -f container/agent-runner/dist/.tsbuildinfo ]; then NEED_AR=1; \
	else \
	  for f in container/agent-runner/package.json container/agent-runner/tsconfig.json; do \
	    if [ -f "$$f" ] && [ "$$f" -nt container/agent-runner/dist/.tsbuildinfo ]; then NEED_AR=1; break; fi; \
	  done; \
	  if [ "$$NEED_AR" = "0" ] && [ -n "$$(find container/agent-runner/src/ -newer container/agent-runner/dist/.tsbuildinfo -name '*.ts' 2>/dev/null | head -1)" ]; then NEED_AR=1; fi; \
	fi; \
	if [ "$$NEED_AR" = "1" ]; then echo " agent-runner changes detected, rebuilding..."; cd container/agent-runner && $(PKG) run build; else echo " agent-runner unchanged, skipping build"; fi

_build-backend-if-stale: ## (内部) 后端变更时重新编译（Node 模式）
	@NEED_BACKEND=0; \
	if [ ! -f dist/index.js ]; then NEED_BACKEND=1; \
	else \
	  for f in package.json tsconfig.json; do \
	    if [ "$$f" -nt dist/index.js ]; then NEED_BACKEND=1; break; fi; \
	  done; \
	  if [ "$$NEED_BACKEND" = "0" ] && [ -n "$$(find src/ -newer dist/index.js -name '*.ts' 2>/dev/null | head -1)" ]; then NEED_BACKEND=1; fi; \
	fi; \
	if [ "$$NEED_BACKEND" = "1" ]; then echo " Backend source changes detected, rebuilding..."; $(PKG) run build; else echo " Backend unchanged, skipping build"; fi

logs: ## 实时查看日志（需配合手动后台运行：make start > /tmp/miniclaw.log 2>&1 &）
	@tail -f /tmp/miniclaw.log

stop: ## 停止监听指定端口的服务进程
	@lsof -ti:$(PORT) -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null && echo " Miniclaw stopped (port $(PORT))" || echo "  Port $(PORT) is not in use, nothing to stop"

status: ## 查看服务运行状态
	@echo "=== Miniclaw service status ==="
	@if lsof -ti:$(PORT) -sTCP:LISTEN >/dev/null 2>&1; then \
	  echo " backend process: running (port $(PORT))"; \
	  curl -s http://localhost:$(PORT)/api/health 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"   health: {d.get('status','unknown')}\")" 2>/dev/null || echo "   health: unavailable"; \
	else \
	  echo " backend process: not running (port $(PORT) is free)"; \
	fi
	@echo ""
	@echo "=== Log files ==="
	@if [ -f /tmp/miniclaw.log ]; then \
	  echo " /tmp/miniclaw.log exists ($$(wc -l < /tmp/miniclaw.log) lines)"; \
	  echo "   last 3 lines:"; \
	  tail -3 /tmp/miniclaw.log | sed 's/^/   /'; \
	else \
	  echo "  /tmp/miniclaw.log does not exist (not started in background mode)"; \
	fi
	@echo ""
	@echo "=== Docker containers ==="
	@docker ps --filter "name=miniclaw" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "   Docker not running or no Miniclaw container"

# ─── Quality ─────────────────────────────────────────────────

typecheck: sync-types typecheck-backend typecheck-web typecheck-agent-runner ## 全量类型检查
	@./scripts/check-stream-event-sync.sh
	@./scripts/check-agent-runner-prompts.sh
	@$(PKG) run docs:check

typecheck-backend:
	$(RUN) tsc --noEmit

typecheck-web:
	cd web && $(RUN) tsc --noEmit

typecheck-agent-runner:
	cd container/agent-runner && $(RUN) tsc --noEmit

test: ## 运行单元测试
	$(RUN) vitest run

format: ## 格式化代码
	$(PKG) run format

format-check: ## 检查代码格式
	$(PKG) run format:check

# ─── Docker Image ─────────────────────────────────────────────

_ensure-docker-image: ## (内部) 从镜像仓库拉取 GitHub Actions 发布的容器镜像
	@if command -v docker >/dev/null 2>&1; then \
	  $(MAKE) --no-print-directory docker-pull; \
	fi

docker-pull: ## 拉取 GitHub Actions 发布的 Agent 镜像
	@echo " Pulling Docker image $(CONTAINER_IMAGE)..."
	@docker pull "$(CONTAINER_IMAGE)"
	@echo " Docker image is ready: $(CONTAINER_IMAGE)"

# ─── Shared Types ────────────────────────────────────────────

sync-types: ## 同步 shared/ 下的类型定义到各子项目
	@./scripts/sync-stream-event.sh

# ─── Pi Runtime ──────────────────────────────────────────────

update-pi-runtime: ## 显式更新 agent-runner 的 Pi Runtime 与 SubAgents 扩展
	@PI_LATEST=$$(npm view @earendil-works/pi-coding-agent version --fetch-timeout=5000); \
	SUBAGENTS_LATEST=$$(npm view @tintinweb/pi-subagents version --fetch-timeout=5000); \
	echo " Updating Pi Runtime -> $$PI_LATEST, SubAgents -> $$SUBAGENTS_LATEST"; \
	$(PKG) --prefix container/agent-runner install --save-exact \
	  @earendil-works/pi-coding-agent@$$PI_LATEST \
	  @tintinweb/pi-subagents@$$SUBAGENTS_LATEST; \
	$(PKG) --prefix container/agent-runner run build; \
	echo " Pi Runtime and runner lockfile updated. Run: make typecheck && npm test -- --run"

update-sdk: update-pi-runtime ## 兼容旧工作流名称；实际更新 Pi Runtime

ensure-latest-pi-runtime: ## 只读检查 Pi Runtime 与 SubAgents 的最新版本
	@PI_LOCAL=$$(node -p "require('./container/agent-runner/node_modules/@earendil-works/pi-coding-agent/package.json').version" 2>/dev/null || echo "0.0.0"); \
	SUBAGENTS_LOCAL=$$(node -p "require('./container/agent-runner/node_modules/@tintinweb/pi-subagents/package.json').version" 2>/dev/null || echo "0.0.0"); \
	PI_LATEST=$$(npm view @earendil-works/pi-coding-agent version --fetch-timeout=5000 2>/dev/null || echo "$$PI_LOCAL"); \
	SUBAGENTS_LATEST=$$(npm view @tintinweb/pi-subagents version --fetch-timeout=5000 2>/dev/null || echo "$$SUBAGENTS_LOCAL"); \
	echo "Pi Runtime: $$PI_LOCAL -> $$PI_LATEST"; \
	echo "SubAgents: $$SUBAGENTS_LOCAL -> $$SUBAGENTS_LATEST";

ensure-latest-sdk: ensure-latest-pi-runtime ## 兼容旧工作流名称；实际检查 Pi Runtime

# ─── Setup ───────────────────────────────────────────────────

install-host-tools: ## 安装宿主工具 + 刷新 Host/Container 共用的固定版本 builtin-skills Manifest 源
	@./scripts/install-host-tools.sh

install: ## 安装全部依赖并编译 agent-runner
	$(PKG) ci
	@# node-pty's prebuilt spawn-helper binary may lack exec permission, causing PTY mode to fail
	@chmod +x node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper 2>/dev/null || true
	cd container/agent-runner && $(PKG) ci
	cd container/agent-runner && $(PKG) run build
	cd web && $(PKG) ci
	@$(MAKE) _ensure-builtin-skills
	@# Update directory mtime to work with start's dependency-change detection ([ package.json -nt node_modules ])
	@touch node_modules web/node_modules container/agent-runner/node_modules

clean: ## 清理构建产物
	rm -rf dist
	rm -rf web/dist
	rm -rf container/agent-runner/dist
	rm -f .build-sentinel

reset-init: ## 完全重置为首装状态（清空所有运行时数据）
	rm -rf data store groups
	@echo " Fully reset to first-install state (database, config, workspaces, memory, sessions all cleared)"

# ─── Backup / Restore ────────────────────────────────────────

backup: ## 备份运行时数据到 miniclaw-backup-{date}.tar.gz
	@set -eu; \
	DATE=$$(date +%Y%m%d-%H%M%S); \
	mkdir -p "$(BACKUP_DIR)"; \
	FILE="$(BACKUP_DIR)/miniclaw-backup-$$DATE.tar.gz"; \
	if [ -e "$$FILE" ]; then FILE="$(BACKUP_DIR)/miniclaw-backup-$$DATE-$$$$.tar.gz"; fi; \
	TMP_FILE="$$FILE.tmp-$$$$"; \
	TMP_ROOT=$$(mktemp -d "$${TMPDIR:-/tmp}/miniclaw-backup.XXXXXX"); \
	trap 'rm -rf "$$TMP_ROOT" "$$TMP_FILE"' EXIT INT TERM; \
	HARDLINK_SOURCE=$$(find "$(RUNTIME_DATA_DIR)" -xdev -type f -links +1 -print -quit 2>/dev/null || true); \
	if [ -n "$$HARDLINK_SOURCE" ]; then \
	  echo " Runtime data contains hardlink files; tar would store them as incomplete link entries making the backup unrecoverable; refusing: $$HARDLINK_SOURCE"; \
	  exit 1; \
	fi; \
	mkdir -p "$$TMP_ROOT/data/db"; \
	echo " Creating SQLite consistent snapshot..."; \
	node scripts/sqlite-snapshot.mjs \
	  "$(RUNTIME_DATA_DIR)/db/messages.db" \
	  "$$TMP_ROOT/data/db/messages.db"; \
	for DIR in config groups sessions skills mcp-servers plugins memory avatars extra builtin-skills; do \
	  if [ -d "$(RUNTIME_DATA_DIR)/$$DIR" ]; then \
	    mkdir -p "$$TMP_ROOT/data/$$DIR"; \
	    cp -a "$(RUNTIME_DATA_DIR)/$$DIR/." "$$TMP_ROOT/data/$$DIR/"; \
	  fi; \
	done; \
	node scripts/prepare-backup-tree.mjs "$$TMP_ROOT/data"; \
	UNSAFE_ENTRY=$$(find "$$TMP_ROOT/data" \( -type l -o \( ! -type f ! -type d \) \) -print -quit); \
	if [ -n "$$UNSAFE_ENTRY" ]; then \
	  echo " Runtime data contains unsafe links or special files; refusing to create an unrecoverable backup: $$UNSAFE_ENTRY"; \
	  exit 1; \
	fi; \
	HARDLINK_ENTRY=$$(find "$$TMP_ROOT/data" -type f -links +1 -print -quit); \
	if [ -n "$$HARDLINK_ENTRY" ]; then \
	  echo " Runtime data contains hardlink files; tar would store them as incomplete link entries making the backup unrecoverable; refusing: $$HARDLINK_ENTRY"; \
	  exit 1; \
	fi; \
	if [ -d "$$TMP_ROOT/data/groups" ]; then \
	  find "$$TMP_ROOT/data/groups" -mindepth 2 -maxdepth 2 -type d -name logs \
	    -prune -exec rm -rf {} +; \
	fi; \
	node scripts/backup-manifest.mjs "$$TMP_ROOT/data"; \
	echo " Packaging backup to $$FILE ..."; \
	tar -czf "$$TMP_FILE" -C "$$TMP_ROOT" data; \
	mv "$$TMP_FILE" "$$FILE"; \
	chmod 600 "$$FILE"; \
	echo " Backup complete: $$FILE ($$(du -sh "$$FILE" | cut -f1))"

restore: ## 从 miniclaw-backup-*.tar.gz 恢复数据（用法：make restore 或 make restore FILE=xxx.tar.gz）
	@set -eu; \
	if [ -n "$(FILE)" ]; then \
	  BACKUP="$(FILE)"; \
	elif [ $$(find "$(BACKUP_DIR)" -maxdepth 1 -type f -name 'miniclaw-backup-*.tar.gz' 2>/dev/null | wc -l) -eq 1 ]; then \
	  BACKUP=$$(find "$(BACKUP_DIR)" -maxdepth 1 -type f -name 'miniclaw-backup-*.tar.gz' | head -1); \
	elif [ $$(find "$(BACKUP_DIR)" -maxdepth 1 -type f -name 'miniclaw-backup-*.tar.gz' 2>/dev/null | wc -l) -gt 1 ]; then \
	  echo " Multiple backup files found; specify one with: make restore FILE=xxx.tar.gz"; \
	  find "$(BACKUP_DIR)" -maxdepth 1 -type f -name 'miniclaw-backup-*.tar.gz' -print; \
	  exit 1; \
	else \
	  echo " No backup file found; put miniclaw-backup-*.tar.gz in the current directory"; \
	  exit 1; \
	fi; \
	if [ ! -f "$$BACKUP" ]; then \
	  echo " Backup file does not exist: $$BACKUP"; \
	  exit 1; \
	fi; \
	if ! node scripts/restore-backup.mjs assert-port-free "$(PORT)"; then \
	  echo " Running service detected; refusing to overwrite the database"; \
	  exit 1; \
	fi; \
	echo " Restoring from $$BACKUP..."; \
	if [ -d "$(RUNTIME_DATA_DIR)" ] && [ "$$(ls -A "$(RUNTIME_DATA_DIR)" 2>/dev/null)" ]; then \
	  echo "  $(RUNTIME_DATA_DIR)/ already contains data; continuing will overwrite it. Continue? [y/N] "; \
	  read CONFIRM; \
	  [ "$$CONFIRM" = "y" ] || [ "$$CONFIRM" = "Y" ] || { echo "Cancelled"; exit 1; }; \
	fi; \
	node scripts/restore-backup.mjs restore "$$BACKUP" "$(RUNTIME_DATA_DIR)" "$(PORT)"; \
	if [ ! -f "$(RUNTIME_DATA_DIR)/config/session-secret.key" ]; then \
	  echo "  Warning: backup is missing session-secret.key; user login cookies will be invalidated and require re-login"; \
	fi; \
	echo " Data restore complete"; \
	echo ""; \
	echo "Next steps:"; \
	echo "  1. Pull the Agent image: docker pull $(CONTAINER_IMAGE)"; \
	echo "  2. Start the service: make start"

# ─── Help ────────────────────────────────────────────────────

help: ## 显示帮助
	@echo "Runtime:  Node.js (this project does not use bun)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
