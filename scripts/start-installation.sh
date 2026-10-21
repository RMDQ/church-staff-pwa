#!/usr/bin/env bash
# Bootstrap only: official pinned tools, then the private installer. No cloud
# resource is created until the person authorizes and confirms in the wizard.
set -euo pipefail
umask 077

if [[ "${1:-}" == '--help' ]]; then
  printf '%s\n' 'Usage: bash scripts/start-installation.sh' '在自己的 Google Cloud Shell 准备固定版本工具，启动私人安装精灵；不会自动建立云端资源。'
  exit 0
fi
if [[ $# -ne 0 ]]; then printf '%s\n' '不接受额外参数。' >&2; exit 1; fi
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 || "${CLOUD_SHELL:-}" != true ]]; then
  printf '%s\n' '请在自己的 Google Cloud Shell 执行此入口（Linux x86_64）。' >&2
  exit 1
fi
# Opening the repository without ticking "trust repository" starts Cloud Shell
# with no Google credentials, so the wizard could never connect Google.
if [[ "${TRUSTED_ENVIRONMENT:-}" == false ]]; then
  printf '%s\n' '这个 Cloud Shell 是「暂时模式」，没有你的 Google 授权，精灵无法建立专案。' \
    '请按 Cloud Shell 右上角的「⋮」，点选单里打勾的「暂时模式」，再按「停用」。' \
    'Cloud Shell 重新启动并请你按「授权」后，回到安装说明页重新按「Open in Cloud Shell」，' \
    '勾选「信任存放区」再照教学做。' >&2
  exit 1
fi
for tool in curl tar xz sha256sum sha512sum base64 awk df mktemp stat od tr flock; do
  command -v "$tool" >/dev/null || { printf '缺少必要工具：%s\n' "$tool" >&2; exit 1; }
done
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ -f "$ROOT/scripts/install-core.mjs" ]] || { printf '%s\n' '找不到安装主程式，请重新开启完整教学。' >&2; exit 1; }
# Reopening the tutorial reuses the earlier clone without updating it. Update
# a clean checkout, unless a wizard is still running from it or an unfinished
# installation was planned by a version the new code cannot continue (its
# scripts/installer/RESUMES_FROM). The tutorial card leaves updating to this
# script when it finds "pull --ff-only --quiet origin" here, so keep that text.
if [[ -z "${INSTALLER_SELF_UPDATED:-}" ]] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  running=''
  for marker in "/tmp/church-core-installer-${UID}"/session-*/.installer-pid; do
    [[ -f "$marker" && ! -L "$marker" ]] && read -r pid < "$marker" && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && running=1
  done
  # Cloud Shell's clone sets the branch upstream to the local repo itself
  # (branch.<name>.remote = .), so a bare `git pull` never fetches anything.
  branch="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD || true)"
  if [[ -n "$running" ]]; then
    printf '%s\n' '另一个安装精灵还在执行，略过自动更新。'
  elif [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]]; then
    printf '%s\n' '程式档案有本机修改，略过自动更新。'
  elif [[ -z "$branch" ]] || ! git -C "$ROOT" fetch --quiet origin "$branch" >/dev/null 2>&1; then
    printf '%s\n' '无法检查新版本，继续使用目前版本。'
  else
    # Resumable means: RESUMES_FROM <= the record's version <= the new code.
    # install-core.mjs (readResumableRevisions) applies the same rule.
    floor="$(git -C "$ROOT" show FETCH_HEAD:scripts/installer/RESUMES_FROM 2>/dev/null | head -n 1 || true)"
    stranded=''
    if ! git -C "$ROOT" merge-base --is-ancestor FETCH_HEAD HEAD 2>/dev/null; then
      for state in "$ROOT"/.local/install/*/state.json; do
        [[ -f "$state" ]] && ! grep -qE '^  "status": "complete",?$' "$state" || continue
        # The plan's own field: a direct child of the top-level "plan" object.
        revision="$(sed -n '/^  "plan": {$/,/^  }/p' "$state" | grep -oE '^    "sourceRevision": "[0-9a-f]{40}"' | grep -oE '[0-9a-f]{40}' || true)"
        if [[ ! "$floor" =~ ^[0-9a-f]{40}$ || ! "$revision" =~ ^[0-9a-f]{40}$ ]] ||
          ! git -C "$ROOT" merge-base --is-ancestor "$floor" "$revision" 2>/dev/null ||
          ! git -C "$ROOT" merge-base --is-ancestor "$revision" FETCH_HEAD 2>/dev/null; then stranded=1; fi
      done
      if [[ -n "$stranded" ]]; then
        printf '%s\n' '有尚未完成的安装纪录，新版本无法接续，维持目前程式版本以便接续。'
      elif git -C "$ROOT" merge --ff-only --quiet FETCH_HEAD >/dev/null 2>&1; then
        printf '%s\n' '已更新到最新版本，重新启动。'
        INSTALLER_SELF_UPDATED=1 exec bash "$ROOT/scripts/start-installation.sh"
      else
        printf '%s\n' '无法自动更新到最新版本，继续使用目前版本。'
      fi
    fi
  fi
fi
# The VM disk, not Cloud Shell's 5 GB persistent home, holds SDKs and caches.
AVAILABLE_KB="$(df -Pk /tmp | awk 'NR==2 {print $4}')"
if [[ ! "$AVAILABLE_KB" =~ ^[0-9]+$ || "$AVAILABLE_KB" -lt 8388608 ]]; then
  printf '%s\n' 'Cloud Shell VM 暂存磁碟至少需要 8 GiB 可用空间；请重启 Cloud Shell 后再试。' >&2
  exit 1
fi
BASE="/tmp/church-core-installer-${UID}"
if [[ -e "$BASE" || -L "$BASE" ]]; then
  [[ -d "$BASE" && ! -L "$BASE" && -O "$BASE" && "$(stat -c %a "$BASE")" == 700 ]] || { printf '%s\n' '安装器暂存目录权限不符，已停止。' >&2; exit 1; }
else
  mkdir -m 700 "$BASE"
fi
# Only this launcher's marked, same-owner, no-longer-running sessions qualify.
# Never enumerate or remove the operator's ~/.wrangler or gcloud profiles.
for old in "$BASE"/session-*; do
  [[ -d "$old" && ! -L "$old" && -O "$old" && -f "$old/.installer-pid" && ! -L "$old/.installer-pid" ]] || continue
  read -r pid < "$old/.installer-pid" || continue
  if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then rm -rf -- "$old"; fi
done
TOOLS="$(mktemp -d "$BASE/session-XXXXXXXX")"
printf '%s\n' "$$" > "$TOOLS/.installer-pid"
server_pid=''
cleanup() {
  trap - EXIT INT TERM
  if [[ -n "$server_pid" ]]; then kill -TERM "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  [[ -d "$TOOLS" && ! -L "$TOOLS" && -O "$TOOLS" ]] && rm -rf -- "$TOOLS"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

NODE_VERSION=22.22.0
FLUTTER_VERSION=3.41.0
WRANGLER_VERSION=4.138.0
# Official release manifests, pinned here rather than trusting a mutable latest.
NODE_SHA256=9aa8e9d2298ab68c600bd6fb86a6c13bce11a4eca1ba9b39d79fa021755d7c37
FLUTTER_SHA256=368ae5b6993c51861324e704c42d61c4e290fba7213a88fd0e9fec15ded54599
WRANGLER_SHA512_B64='jxNlOfssgyMo+eUcWBX+BxAuU6/AZAn8mNimicLv4igxbRH40OFRBMtGJT8z4kJwXPJriy1O4TB7A8lYjKb82w=='
# Verified tools are kept on this VM's disk, so relaunching the wizard (after
# Ctrl+C, a closed tab or a crash) does not download 1.5 GB again. A marker is
# written only after its download passed the checksum and finished unpacking.
# Cloud Shell wipes /tmp when it recycles the VM; then everything downloads again.
CACHE="$BASE/tools"
if [[ -e "$CACHE" || -L "$CACHE" ]]; then
  [[ -d "$CACHE" && ! -L "$CACHE" && -O "$CACHE" && "$(stat -c %a "$CACHE")" == 700 ]] || { printf '%s\n' '工具暂存目录权限不符，已停止。' >&2; exit 1; }
else
  mkdir -m 700 "$CACHE"
fi
exec 9>"$CACHE/.lock"
flock -n 9 || { printf '%s\n' '另一个安装精灵正在准备工具，等它完成后会继续…'; flock 9; }
ready() { [[ -f "$CACHE/$1.ready" && ! -L "$CACHE/$1.ready" && "$(cat "$CACHE/$1.ready")" == "$2" ]]; }
mark() { printf '%s' "$2" > "$CACHE/$1.ready"; }
reuse() { printf '%s\n' '这台 Cloud Shell 已下载并核对过，直接使用。'; }
# The progress bar is the only sign of life during a multi-minute download.
download() { curl --proto '=https' --tlsv1.2 --fail --progress-bar --show-error --retry 3 --max-time 900 "$1" -o "$2"; }
stage() { printf '\n[%s/4] %s\n' "$1" "$2"; }
verify() { printf '%s  %s\n' "$1" "$2" | sha256sum --check --status || { printf '%s\n' '官方工具 checksum 不符，已停止；没有执行下载内容。' >&2; exit 1; }; }
printf '%s\n' '正在准备固定版本 Node、Flutter 与 Wrangler。第一次通常需要 3–10 分钟；进度条在动就代表还在进行。'
stage 1 '准备 Node.js（约 30 MB）'
NODE_DIR="$CACHE/node-v${NODE_VERSION}-linux-x64"
if ready "node-$NODE_VERSION" "$NODE_SHA256" && [[ -x "$NODE_DIR/bin/node" ]]; then reuse
else
  rm -rf -- "$NODE_DIR" "$CACHE/node.tar.xz"
  download "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" "$CACHE/node.tar.xz"
  verify "$NODE_SHA256" "$CACHE/node.tar.xz"
  tar -xJf "$CACHE/node.tar.xz" -C "$CACHE"
  rm "$CACHE/node.tar.xz"
  mark "node-$NODE_VERSION" "$NODE_SHA256"
fi
export PATH="$NODE_DIR/bin:$PATH"
stage 2 '准备 Flutter（约 1.5 GB，最久的一步）'
FLUTTER_DIR="$CACHE/flutter-${FLUTTER_VERSION}"
if ready "flutter-$FLUTTER_VERSION" "$FLUTTER_SHA256" && [[ -x "$FLUTTER_DIR/flutter/bin/flutter" ]]; then reuse
else
  rm -rf -- "$FLUTTER_DIR" "$CACHE/flutter.tar.xz"
  download "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" "$CACHE/flutter.tar.xz"
  verify "$FLUTTER_SHA256" "$CACHE/flutter.tar.xz"
  printf '%s\n' '下载完成，正在解压缩（约 1–3 分钟，这段没有进度条）…'
  mkdir -m 700 "$FLUTTER_DIR"
  tar -xJf "$CACHE/flutter.tar.xz" -C "$FLUTTER_DIR"
  rm "$CACHE/flutter.tar.xz"
  mark "flutter-$FLUTTER_VERSION" "$FLUTTER_SHA256"
fi
mkdir -m 700 "$TOOLS/npm-cache" "$TOOLS/builds" "$TOOLS/sessions"
# Dart packages are checksum-verified by pub; reusing them speeds up the build.
[[ -d "$CACHE/pub-cache" ]] || mkdir -m 700 "$CACHE/pub-cache"
stage 3 '准备 Wrangler'
WRANGLER_DIR="$CACHE/wrangler-${WRANGLER_VERSION}"
if ready "wrangler-$WRANGLER_VERSION" "$WRANGLER_SHA512_B64" && [[ -x "$WRANGLER_DIR/node_modules/.bin/wrangler" ]]; then reuse
else
  rm -rf -- "$WRANGLER_DIR"
  mkdir -m 700 "$WRANGLER_DIR"
  : > "$TOOLS/npmrc"
  : > "$TOOLS/global-npmrc"
  download "https://registry.npmjs.org/wrangler/-/wrangler-${WRANGLER_VERSION}.tgz" "$TOOLS/wrangler.tgz"
  EXPECTED="$(printf '%s' "$WRANGLER_SHA512_B64" | base64 -d | od -An -v -tx1 | tr -d ' \n')"
  printf '%s  %s\n' "$EXPECTED" "$TOOLS/wrangler.tgz" | sha512sum --check --status || { printf '%s\n' 'Wrangler checksum 不符，已停止。' >&2; exit 1; }
  # npm validates dependency tarball integrity. Disable lifecycle scripts and do
  # not read ~/.npmrc, inherited auth, or the checkout's production environment.
  (cd "$WRANGLER_DIR" && env -i PATH="$PATH" HOME="$WRANGLER_DIR" npm_config_cache="$TOOLS/npm-cache" \
    npm_config_userconfig="$TOOLS/npmrc" npm_config_globalconfig="$TOOLS/global-npmrc" npm_config_update_notifier=false \
    npm install --prefix "$WRANGLER_DIR" --ignore-scripts --no-audit --no-fund \
    --registry=https://registry.npmjs.org "$TOOLS/wrangler.tgz")
  rm "$TOOLS/wrangler.tgz"
  mark "wrangler-$WRANGLER_VERSION" "$WRANGLER_SHA512_B64"
fi
flock -u 9
export INSTALLER_TOOL_ROOT="$TOOLS"
export INSTALLER_FLUTTER="$FLUTTER_DIR/flutter/bin/flutter"
export INSTALLER_WRANGLER="$WRANGLER_DIR/node_modules/.bin/wrangler"
export INSTALLER_BUILD_ROOT="$TOOLS/builds"
export INSTALLER_SESSION_ROOT="$TOOLS/sessions"
export PUB_CACHE="$CACHE/pub-cache"
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
# Do not replace HOME here: Google Cloud Shell's own authorization remains the
# operator identity. Adapters isolate their child-process environments instead.
stage 4 '启动安装精灵'
printf '%s\n' '工具已就绪。开启私人 Web Preview 后，仍须本人登入、填表并确认建立资源。'
unset NODE_OPTIONS NODE_EXTRA_CA_CERTS
node "$ROOT/scripts/install-core.mjs" --cloud-shell &
server_pid=$!
wait "$server_pid"
server_pid=''
