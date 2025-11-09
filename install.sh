#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

# colors
re="\033[0m"
red_c="\033[1;91m"
green_c="\e[1;32m"
yellow_c="\e[1;33m"
purple_c="\e[1;35m"
red()   { echo -e "${red_c}$1${re}"; }
green() { echo -e "${green_c}$1${re}"; }
yellow(){ echo -e "${yellow_c}$1${re}"; }
purple(){ echo -e "${purple_c}$1${re}"; }

# Basic info
HOSTNAME="$(hostname)"
USERNAME="$(whoami | tr '[:upper:]' '[:lower:]')"
export DOMAIN="${DOMAIN:-''}"

# Determine CURRENT_DOMAIN if DOMAIN not provided
if [[ -z "$DOMAIN" ]]; then
    if [[ "$HOSTNAME" =~ ct8 ]]; then
        CURRENT_DOMAIN="${USERNAME}.ct8.pl"
    elif [[ "$HOSTNAME" =~ hostuno ]]; then
        CURRENT_DOMAIN="${USERNAME}.useruno.com"
    else
        CURRENT_DOMAIN="${USERNAME}.serv00.net"
    fi
else
    CURRENT_DOMAIN="$DOMAIN"
fi

# Workdir for MoonTV
WORKDIR="${HOME}/domains/${CURRENT_DOMAIN}/public_moontv"

# Ensure required commands exist
command -v git >/dev/null 2>&1 || { red "Error: git 未安装，请先安装 git"; exit 1; }
command -v node >/dev/null 2>&1 || { red "Error: node 未安装或未在 PATH 中。请安装 Node.js (建议 18/20+) 并重试。"; exit 1; }

# prefer pnpm if available (repo contains pnpm-lock.yaml)
if command -v pnpm >/dev/null 2>&1; then
  PKG_TOOL="pnpm"
elif command -v npm >/dev/null 2>&1; then
  PKG_TOOL="npm"
else
  red "Error: 未找到 pnpm 或 npm，请先安装其中之一。"
  exit 1
fi

# Create workdir
mkdir -p "$WORKDIR"
chmod 755 "$WORKDIR"

# Repo info
REPO="https://github.com/shanke5589/MoonTV.git"
BRANCH="${BRANCH:-main}"

green "开始部署 MoonTV 到：${WORKDIR}"
yellow "使用仓库： ${REPO} （分支：${BRANCH}）"
yellow "使用包管理器： ${PKG_TOOL}"
echo

# Clone or update repo
if [[ -d "${WORKDIR}/.git" ]]; then
  green "检测到已存在仓库，执行 pull 更新..."
  git -C "$WORKDIR" fetch --all --prune
  git -C "$WORKDIR" reset --hard "origin/${BRANCH}" || git -C "$WORKDIR" checkout -B "${BRANCH}" "origin/${BRANCH}"
else
  green "克隆仓库到 ${WORKDIR} ..."
  rm -rf "${WORKDIR:?}"/*
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$WORKDIR"
fi

cd "$WORKDIR"

# If project uses pnpm lock, recommend pnpm; try to install pnpm if missing (but don't auto-sudo)
if [[ "$PKG_TOOL" == "pnpm" ]]; then
  green "使用 pnpm 安装依赖..."
  pnpm install --frozen-lockfile
else
  # npm workflow: install dev deps for build, then prune production deps if desired
  green "使用 npm 安装依赖（会安装 devDependencies 以便构建）。"
  npm ci || npm install
fi

# Build step (Next.js)
if grep -q "\"build\"" package.json 2>/dev/null; then
  green "开始构建项目（npm run build / pnpm build）..."
  if [[ "$PKG_TOOL" == "pnpm" ]]; then
    pnpm run build
  else
    npm run build
  fi
else
  yellow "package.json 中未发现 build 脚本，跳过构建步骤。"
fi

# Create symlinks to node/npm in ~/bin so panel tools expecting /usr/local/bin/node22 之类更容易适配
mkdir -p "$HOME/bin"
ln -fs "$(command -v node)" "$HOME/bin/node" || true
if command -v npm >/dev/null 2>&1; then ln -fs "$(command -v npm)" "$HOME/bin/npm" || true; fi
if command -v pnpm >/dev/null 2>&1; then ln -fs "$(command -v pnpm)" "$HOME/bin/pnpm" || true; fi
export PATH="$HOME/bin:$PATH"

# Configure vhost via devil if available
if command -v devil >/dev/null 2>&1; then
  NODE_PATH="$(command -v node)"
  # ensure vhost is nodejs pointing to our node binary
  if devil www list | awk '{print $1}' | grep -qx "$CURRENT_DOMAIN"; then
    green "发现已存在 vhost，先删除再重建..."
    devil www del "$CURRENT_DOMAIN" >/dev/null 2>&1 || true
  fi
  devil www add "$CURRENT_DOMAIN" nodejs "$NODE_PATH" >/dev/null 2>&1 || true
  devil www restart "$CURRENT_DOMAIN" >/dev/null 2>&1 || true
  green "vhost 已创建/重启 (via devil)。"
else
  yellow "系统上未检测到 'devil' 命令，跳过自动创建 vhost。请手工在面板或 nginx 中配置站点，指向：${WORKDIR}/ (Next.js 静态或反向代理到 node 服务)"
fi

# Try to start using pm2 if available / desired
if command -v pm2 >/dev/null 2>&1; then
  # Determine start script or default Next start
  START_CMD=""
  if grep -q "\"start\"" package.json 2>/dev/null; then
    START_CMD="npm run start"
  else
    # Next.js production start: next start -p 3000 (requires .next build)
    START_CMD="npx next start -p 3000"
  fi

  green "使用 pm2 启动进程（pm2 已检测到）。"
  pm2 delete "moontv-${USERNAME}-${CURRENT_DOMAIN}" >/dev/null 2>&1 || true
  # Use PM2 with platform-specific invocation; let pm2 run via npm if start script exists
  if [[ "$PKG_TOOL" == "pnpm" ]]; then
    pm2 start --name "moontv-${USERNAME}-${CURRENT_DOMAIN}" --interpreter "$(command -v node)" -- "node" "node_modules/.bin/next" "start" "--port" "3000"
  else
    if grep -q "\"start\"" package.json 2>/dev/null; then
      pm2 start npm --name "moontv-${USERNAME}-${CURRENT_DOMAIN}" -- start
    else
      pm2 start --name "moontv-${USERNAME}-${CURRENT_DOMAIN}" --interpreter "$(command -v node)" node_modules/.bin/next start -- --port 3000
    fi
  fi
  pm2 save >/dev/null 2>&1 || true
  green "pm2 已启动 MoonTV（名称：moontv-${USERNAME}-${CURRENT_DOMAIN}）。"
else
  yellow "pm2 未检测到，未自动托管进程。建议安装 pm2 或配置 systemd/nginx 反向代理以保持服务常驻。"
fi

# Final info for DNS / access
if [[ -z "$DOMAIN" ]]; then
  # check local https
  if curl -o /dev/null -s -w "%{http_code}\n" "https://${CURRENT_DOMAIN}" | grep -q '^200$'; then
    green "MoonTV 已部署并可通过 https://${CURRENT_DOMAIN} 访问（返回码 200）。"
  else
    yellow "部署完成，但通过 https://${CURRENT_DOMAIN} 测试未返回 200，请检查防火墙/面板/反向代理。"
  fi
else
  # try to get panel ip if devil available
  if command -v devil >/dev/null 2>&1; then
    ip_address=$(devil vhost list | awk '$2 ~ /web/ {print $1; exit}')
    if [[ -n "$ip_address" ]]; then
      purple "请在 Cloudflare 中把 ${CURRENT_DOMAIN} 的 A 记录指向：${ip_address} 并开启代理（小黄云），然后访问 https://${CURRENT_DOMAIN} 检查。"
    fi
  fi
fi

echo
green "站点路径： ${WORKDIR}"
green "访问（默认）： https://${CURRENT_DOMAIN}  或 http://<your-server-ip>:3000 (若你使用 next start 在 3000 端口)"
yellow "若你使用 Vercel/Docker，脚本已把代码拉下并构建，可改为按照 README 的 Docker 或 Vercel 指南部署。"
red "温馨提示：首次登录请在管理页面设置 PASSWORD 环境变量或在 config.json 中配置管理员。"

exit 0
