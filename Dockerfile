# Public settings are validated once and staged; no local credentials enter
# either image. The static nginx image intentionally excludes server integrations.
ARG BUILDPLATFORM
FROM --platform=$BUILDPLATFORM node:22-bookworm-slim AS deployment
WORKDIR /source
COPY config/ config/
COPY scripts/ scripts/
COPY worker/ worker/
COPY functions/ functions/
COPY web/ web/
COPY firestore.rules ./
ARG CHURCH_CONFIG_JSON=""
RUN test -n "$CHURCH_CONFIG_JSON" \
    || { echo "CHURCH_CONFIG_JSON build-arg is required" >&2; exit 1; }; \
    printf '%s' "$CHURCH_CONFIG_JSON" > church.json; \
    node scripts/prepare-deployment.mjs --config church.json --out /deployment
RUN node --input-type=module -e "import fs from 'node:fs'; const c=JSON.parse(fs.readFileSync('/deployment/church.json')); if(c.features.calendar || c.features.photoImport || c.features.lineNotifications) throw Error('Static nginx does not run Pages Functions. Disable calendar/photoImport/lineNotifications or deploy to Cloudflare Pages.');"

# Stage 1: 建置环境 (使用 build host 以确保 Flutter SDK 相容性与编译速度)
# 我们产出的是静态 HTML/JS，所以在哪里编译都没关系
FROM --platform=$BUILDPLATFORM ubuntu:22.04 AS builder

# 安装 Flutter 依赖
RUN apt-get update && apt-get install -y \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    libglu1-mesa \
    && rm -rf /var/lib/apt/lists/*

# 下载 Flutter SDK。版本固定，与 .github/workflows/deploy-flutter-pwa.yml
# 的 FLUTTER_VERSION 保持一致；跟著 stable 浮动会让 image 某天无预警坏掉。
ARG FLUTTER_VERSION=3.41.0
ENV FLUTTER_HOME="/usr/local/flutter"
RUN git clone --depth 1 https://github.com/flutter/flutter.git \
    -b ${FLUTTER_VERSION} $FLUTTER_HOME

# 设定环境变数
ENV PATH="$FLUTTER_HOME/bin:$FLUTTER_HOME/bin/cache/dart-sdk/bin:${PATH}"

# 预先下载 Dart SDK 与依赖，加速后续构建
RUN flutter config --enable-web

# 设定工作目录
WORKDIR /app

# 复制专案档案 (分层复制以利用 Docker Cache)
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

# 复制其余原始码
COPY . .
COPY --from=deployment /deployment /deployment

# CI 那条路径会在 build 前生出 web/version.json，App 的 AppVersionService
# 就是读它来显示「上次更新」。自架这条原本没有这一步，/version.json 直接 404，
# 版本日期永远是空的。两条部署路径的产物要一致。
RUN set -eu; \
    GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
    mkdir -p web; \
    printf '{\n  "version": "docker-%s",\n  "build_number": "0",\n  "branch": "docker",\n  "generated_at": "%s"\n}\n' \
      "$(date -u +%Y%m%d%H%M%S)" "$GENERATED_AT" > web/version.json

# 建置时注入的设定。FIREBASE_* 少给的话，编出来的 App 连 Firebase 都
# 初始化不了（原本这里只传了 VAPID key，等于产出不能用的 image）。
ARG FCM_WEB_VAPID_KEY=""
ARG FIREBASE_API_KEY=""
ARG FIREBASE_AUTH_DOMAIN=""
ARG FIREBASE_PROJECT_ID=""
ARG FIREBASE_STORAGE_BUCKET=""
ARG FIREBASE_MESSAGING_SENDER_ID=""
ARG FIREBASE_APP_ID=""
ARG FIREBASE_MEASUREMENT_ID=""
ARG GOOGLE_CALENDAR_API_KEY=""
ARG GOOGLE_CALENDAR_ID=""

# 编译 Web 版本 (Release Mode)
# 每个 Firebase.initializeApp 必要的栏位都要检查 —— 只挡 API key 的话，
# 少给 projectId 一样会编出一个在浏览器里开不起来的 image。检查不通过时
# `exit 1` 会直接结束这个 RUN 的 shell，后面的 flutter build 不会跑到。
#
# --dart-define 的每个值都要加引号：GOOGLE_CALENDAR_ID 这种可能带空白的值
# 没加引号会被 shell 拆成两个参数，flutter 收到残缺的 define 却照样编过，
# 错误要到执行期才浮出来。
RUN for required in FIREBASE_API_KEY FIREBASE_AUTH_DOMAIN FIREBASE_PROJECT_ID \
                    FIREBASE_MESSAGING_SENDER_ID FIREBASE_APP_ID; do \
      eval "value=\${$required}"; \
      if [ -z "$value" ]; then \
        echo "ERROR: $required build-arg is empty; the image would be non-functional." >&2; \
        exit 1; \
      fi; \
    done; \
    flutter build web --release --base-href / --no-web-resources-cdn \
    --dart-define-from-file=/deployment/dart-defines.json \
    --dart-define=FCM_WEB_VAPID_KEY="${FCM_WEB_VAPID_KEY}" \
    --dart-define=FIREBASE_API_KEY="${FIREBASE_API_KEY}" \
    --dart-define=FIREBASE_AUTH_DOMAIN="${FIREBASE_AUTH_DOMAIN}" \
    --dart-define=FIREBASE_PROJECT_ID="${FIREBASE_PROJECT_ID}" \
    --dart-define=FIREBASE_STORAGE_BUCKET="${FIREBASE_STORAGE_BUCKET}" \
    --dart-define=FIREBASE_MESSAGING_SENDER_ID="${FIREBASE_MESSAGING_SENDER_ID}" \
    --dart-define=FIREBASE_APP_ID="${FIREBASE_APP_ID}" \
    --dart-define=FIREBASE_MEASUREMENT_ID="${FIREBASE_MEASUREMENT_ID}" \
    --dart-define=GOOGLE_CALENDAR_API_KEY="${GOOGLE_CALENDAR_API_KEY}" \
    --dart-define=GOOGLE_CALENDAR_ID="${GOOGLE_CALENDAR_ID}"

RUN cp -R /deployment/web/. build/web/

# 与 CI 相同：把版本号填进 cache_sw.js，并把 Firebase 设定填进推播 SW。
# 少了这步，自架版的 SW cache 永远不会失效，使用者会卡在第一次载入的版本。
#
# 跟 CI 一样要 fail-fast。sed 没对到 placeholder 时退出码还是 0，image 会
# 顺利 build 完、nginx 也照常起来，只是 SW 带著字面上的 __BUILD_VERSION__
# 与 __FIREBASE_API_KEY__ 上线 —— 快取永不失效、背景推播无声失效，
# 两件事都要等使用者回报才会知道。
RUN set -eu; \
    for placeholder in __BUILD_VERSION__ __VENDOR_VERSION__; do \
      grep -q "$placeholder" build/web/cache_sw.js \
        || { echo "ERROR: $placeholder not found in build/web/cache_sw.js" >&2; exit 1; }; \
    done; \
    for placeholder in __FIREBASE_API_KEY__ __FIREBASE_AUTH_DOMAIN__ \
                       __FIREBASE_PROJECT_ID__ __FIREBASE_STORAGE_BUCKET__ \
                       __FIREBASE_MESSAGING_SENDER_ID__ __FIREBASE_APP_ID__ \
                       __FIREBASE_MEASUREMENT_ID__; do \
      grep -q "$placeholder" build/web/firebase-messaging-sw.js \
        || { echo "ERROR: $placeholder not found in build/web/firebase-messaging-sw.js" >&2; exit 1; }; \
    done; \
    BUILD_VERSION="$(date -u +%Y%m%d%H%M%S)"; \
    sed -i \
      -e "s|__BUILD_VERSION__|${BUILD_VERSION}|g" \
      -e "s|__VENDOR_VERSION__|flutter-${FLUTTER_VERSION}|g" \
      build/web/cache_sw.js; \
    sed -i \
      -e "s|__FIREBASE_API_KEY__|${FIREBASE_API_KEY}|g" \
      -e "s|__FIREBASE_AUTH_DOMAIN__|${FIREBASE_AUTH_DOMAIN}|g" \
      -e "s|__FIREBASE_PROJECT_ID__|${FIREBASE_PROJECT_ID}|g" \
      -e "s|__FIREBASE_STORAGE_BUCKET__|${FIREBASE_STORAGE_BUCKET}|g" \
      -e "s|__FIREBASE_MESSAGING_SENDER_ID__|${FIREBASE_MESSAGING_SENDER_ID}|g" \
      -e "s|__FIREBASE_APP_ID__|${FIREBASE_APP_ID}|g" \
      -e "s|__FIREBASE_MEASUREMENT_ID__|${FIREBASE_MEASUREMENT_ID}|g" \
      build/web/firebase-messaging-sw.js; \
    if grep -n '__BUILD_VERSION__\|__VENDOR_VERSION__' build/web/cache_sw.js \
       || grep -n '__FIREBASE_[A-Z_]*__' build/web/firebase-messaging-sw.js; then \
      echo "ERROR: placeholders remain after substitution" >&2; exit 1; \
    fi

# Stage 2: 执行环境 (目标架构 armv7)
# Nginx Alpine 版本支援多架构，包括 linux/arm/v7
FROM nginx:alpine

# 移除预设 Nginx 设定
RUN rm /etc/nginx/conf.d/default.conf

# 复制我们自定义的 Nginx 设定
COPY nginx.conf /etc/nginx/conf.d/default.conf

# 从 Builder 阶段复制编译好的静态档案
COPY --from=builder /app/build/web /usr/share/nginx/html

# 开放 80 port
EXPOSE 80

# 启动 Nginx
CMD ["nginx", "-g", "daemon off;"]
