# 教会同工助手 · Church Staff PWA

以 Flutter Web 制作的简体中文教会同工工具，提供服事表、帐号及权限管理，可选接 Google Calendar、照片汇入与通知。各教会自行持有并管理自己的 **Firebase 专案与 Cloudflare Pages 专案**，不共用上游的帐号、资料库、日历或凭证。

原始程式码采 [MIT License](LICENSE)，著作权人为 Hans Lee。这是可自行部署的开源专案，**不是代管服务；不承诺客服、维运、回应时间或第三方免费额度**。

## 不会写程式？用安装精灵

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https%3A%2F%2Fgithub.com%2Fhansli112%2Fchurch-staff-pwa&cloudshell_git_branch=main&cloudshell_workspace=.&cloudshell_tutorial=docs%2Finstall-cloud-shell.md&show=terminal)

按上面的按钮，照 Cloud Shell 右侧的中文教学一步步做，大约 30 分钟就能架好你们教会自己的同工助手（登入、同工管理、服事表）。不用安装任何软体，也不需要 GitHub 帐号；网站和资料都在你们教会自己的 Google／Cloudflare 帐号里，不会绑定付费方案。

- 按下按钮后，Google 会问是否「信任存放区」：**先勾选「信任存放区」，再按「确认」**。接著跳出「授权 Cloud Shell」时按「授权」。
- 完整图文步骤见 **[安装教学](docs/install-cloud-shell.md)**。
- 已经装过的网站，也是用同一颗按钮更新到新版本，还可以顺便换教会 Logo、设定自订网址。

## 第一版范围

- 服事表：设定每周固定聚会的星期、显示名称及稳定 ID，分配同工、编辑服事项目、换班与特殊活动标记。
- **没有单周新增聚会、改期、停办或任意日期的例外排程**；特殊活动标签不会改变周期。
- 帐号：Firebase Auth Email/Password 登入，Firestore `users/{uid}` 储存角色、牧区与编辑群组。
- 一个部署使用一个 IANA 时区，例如 `Asia/Taipei`；不要把 UTC offset 当时区，也不要只因标签改名就改资料 ID。
- 行事历选用 **Google Calendar**；没有内建 Firestore 行事历，也没有设定日历时的假资料替代品。未启用或缺读取设定时隐藏入口。
- PWA：可加入主画面，提供静态资源快取及版本更新；**不代表所有功能可离线使用**，行事历写入等操作需要网路。
- 照片辨识、推播、LINE webhook 及每日灵粮都是选用功能，范例设定预设关闭。

## 第一次部署（工程师路线）

完整顺序、首位管理员及旧站切换注意事项见 **[部署指南](docs/deployment.md)**。行事历、照片辨识、通知、每日灵粮等选用整合，以及不是用安装精灵架的既有网站，请走这条路线；精灵装的网站用精灵更新即可。

想先看安装精灵的介面、不连任何云端：`node scripts/install-core.mjs --demo`，再开启终端机显示的连结。

1. Fork 原始码；安装 Flutter（CI 使用 `3.41.0`、Dart 需求见 `pubspec.yaml`）、Node.js 22+、Firebase CLI、Google Cloud CLI 与 Wrangler。
2. 建立自己的 Firebase 专案，启用 Email/Password 与 Firestore `(default)` 资料库；建立自己的 Cloudflare Pages 专案。
3. 复制 `config/church.example.json` 到 **gitignored** 的 `.local/church.json`，填自己的公开显示设定；build 用的 Firebase Web 设定与伺服器 secrets 分开存放。
4. 用 `scripts/prepare-deployment.mjs` 从同一份设定产生 Flutter defines、Worker 设定与 Firestore rules。**先审查并明确部署产生的 rules，再部署对应的前后端**，不可只部署 repo 的预设 rules。
5. 在 Firebase Console 建立首位管理员的 Auth 帐号，核对 UID 后，以 `scripts/bootstrap-admin.mjs` 建立一次性、create-only 的 admin profile。它预设完全离线 dry-run，不会把任意登入者自动升成管理员。
6. 依部署指南设定 GitHub Actions。`main`／`dev` push 会触发部署；必须提供自己的完整设定与凭证，缺少时 fail-fast。repo 不包含任何教会的可用生产凭证。

不要直接在新的分支执行旧部署工具去连既有站台；不要把真实姓名、同工名单、日历 ID、照片、金钥或私有设定提交到公开 repo。新增忽略规则不会移除已进入 Git 历史的内容；曾外泄的真正 secrets 仍须撤销／轮替。

## 共用设定

`config/church.example.json` 是可公开的中性范例。私有部署档仅在 build 时输入，生成档留在 `build/` 或 `.local/`，不覆写 tracked source。

| 栏位 | 意义 |
|---|---|
| `appName` / `shortName` | Flutter、网页 title/meta/载入画面与 PWA manifest 的名称 |
| `timeZone` | 单一 IANA 时区，前后端使用同一值 |
| `services[].id` | Firestore 及 API 使用的 stable ID；**建立资料后不可直接改名或删除** |
| `services[].label` / `name` / `weekday` | 短名、完整显示名、星期（1=周一，7=周日） |
| `services[].enabled` | 停用聚会时改为 `false`，保留 ID 与历史资料的可辨识性；不做资料删除／迁移 |
| `features` | `calendar`、`photoImport`、`pushNotifications`、`lineNotifications` 的启用开关 |
| `devotional` | `enabled`、`dataUrl`、`linkUrl`、`sourceName`，选填 `fetchUrl`／`fetchFormat`；不绑定特定教会网站 |
| `icons` | favicon、192/512 px 与 maskable PNG 图示路径；客制素材需自行确认权利 |

设定内容会送到浏览器，**不是秘密保管箱**。`CHURCH_CONFIG_JSON` 不放 API 私钥、service account JSON、Webhook secret 或人员名单。更改设定后重新产生、测试及部署；不是在浏览器里即时改设定。

## 选用整合

### Google Calendar

读取使用 `GOOGLE_CALENDAR_ID` 与限制用途的 `GOOGLE_CALENDAR_API_KEY`，适用可公开读取的日历。**公开日历的内容不因 App 有登入而变成私密资料**；需要私密行事历者必须另做后端读取／OAuth，第一版未提供。

新增／编辑／删除经同源 Cloudflare Pages Functions 写入同一本日历，以 Firebase ID token 和 `users/{uid}` 验证权限。写入用 `GOOGLE_SERVICE_ACCOUNT_JSON` **只放 Cloudflare Secret**，并将日历分享给该 service account（变更活动权限）。这个写入 service account 不需要用来绕过 Firestore rules。

### 照片汇入与通知

- 照片汇入：先完成[首次初始化](docs/deployment.md#照片汇入首次初始化)：建立各聚会的服事项目与事件选项文件，以同一份教会设定产生、检查并明确发布 `settings/import_prompts`；只设 key 不会建立模板。再启用 `photoImport`，在 Cloudflare Secret 设 `GEMINI_API_KEY`，重新产生并部署设定。`--publish` 是实际 Firestore 写入，需先确认专案、权限及内容，不是离线预览。辨识结果必须由人校对再汇入，尤其是人员顺序与日期。照片及所需名单会交给第三方模型处理，部署者须先取得合适的授权／同意并确认供应商条款、资料政策及额度。不要把 key 传入 `--dart-define`。
- 推播：启用 `pushNotifications` 并设定 `FCM_WEB_VAPID_KEY`。浏览器支援及使用者授权仍是必要条件；这是接收端整合，不包含完整的自动发送／排班提醒服务。
- LINE：启用 `lineNotifications`，另接自己的 n8n 或相容 HTTPS webhook，设定 `NOTIFY_WEBHOOK_URL` 与 `NOTIFY_WEBHOOK_SECRET`。没有预设 LINE 群组或托管 workflow。通知接收端须验证 `x-notify-secret`，自行管理 LINE token、群组与个资。新增日历活动后才通知，通知失败不回滚已建立的活动。
- Production 与 Preview 的 Cloudflare secrets **分开设定**；建议 Preview 使用独立测试日历与通知目标，不要预设都发到正式群组。

### 每日灵粮

可直接读部署者有权使用、允许浏览器跨来源读取的 JSON feed；`linkUrl` 是使用者点击后前往的网站，`sourceName` 是显示的来源名称。既有格式如下（日期依部署时区）：

```json
{
  "date": "2026-09-24",
  "rawRange": "约翰福音 1:1-5",
  "fetchedAt": "2026-09-24T00:00:00Z"
}
```

范例仅示意格式，不是即时资料。来源没有当天日期时不会把旧范围当成今天。

`.github/workflows/fetch-daily-verse.yml` 是**选用的来源适配流程，不是任意 HTML 爬虫**：

- 与部署共用 GitHub Secret／Variable `CHURCH_CONFIG_JSON`；只在 `devotional.enabled=true` 且 `devotional.fetchUrl` 非空时抓取。没有设定便不抓，没有任何预设站点。
- 日期判断直接使用同份设定的 `timeZone`，不再另设一组 feed／时区变数；排程仍是 UTC（预设每日 17:00），不会依设定自动改 cron。
- `fetchFormat:'json'`（预设）接受上面的既有 JSON 格式；`fetchFormat:'dailyBibleHtml'` 保留旧的固定 HTML adapter，只接受「日期、`<span>|</span>`、经文范围 `<span>`」结构。不同网站或来源版型改变时，须另写适配器与测试，不会猜测任意 HTML。
- `fetchUrl` 必须是直接回应所选格式的 HTTPS URL（不跟随 redirect）；检查格式与日期后只将必要栏位写入 `data` 分支的 `daily-verse.json`，分支不存在会建立。允许 repository 的 Actions 写入权限后才可更新资料分支。
- `dataUrl` 是 **App 读取 JSON 的位置**，不是抓取来源；`linkUrl` 是点击后的网站。`dataUrl` 不能指向 GitHub HTML 档案预览页。若已有可靠 JSON feed，也可直接读取并把 `fetchUrl` 留空。
- **不跳过 TLS 凭证验证**。既有来源若凭证链不完整，应修正来源凭证、提供正确且受信任的 CA，或改用其他合法来源，不可恢复 `--insecure`。公开 repo 的 data 分支也是公开资料，复制前须自行确认再散布权利；网页可读不等于可任意使用。

## 权限与资料安全

`role` 表示身分；`admin` 有全部权限，其他人的编辑权限由 `groups` 控制，服事表另受 `zones`／`zoneTypes` 限制。stable service IDs、`roster-editors`、`calendar-editors` 都是资料格式的一部分。

| 动作 | admin | roster-editors | calendar-editors |
|---|---|---|---|
| 编辑服事表 | 全部启用聚会 | 自己的牧区 | 不授予 |
| 修改 Google Calendar | 可（已启用／已设定） | 不授予 | 可（已启用／已设定） |
| 读取使用者完整名单 | 可 | 可 | 不授予 |
| 帐号、角色、群组与范本管理 | 可 | 不可 | 不可 |

Firestore rules 才是资料库防线，隐藏按钮不是授权。`zoneTypes` 是 `zones` 的投影；直接在 Console 写资料时也须保持一致。删除 `users/{uid}` 撤销 App 资料存取，不等于删除 Firebase Auth 帐号。

**隐私提醒**：Firestore 没有栏位级读取遮罩；可读使用者名单的服事表编辑者也能读那些文件中的 email、推播 token 等栏位。授权前请理解此范围，收集资料以必要为限。部署者负责备份、删除、存取检查、帐号停用与事故处理。

Firebase Web API key、Google Calendar 前端 API key、FCM VAPID **公钥**最终都可从浏览器取得，即使 build 时从 GitHub Secrets 注入也不会变成秘密。应设定 Firebase authorized domains、正确 rules、Google API 用途及 HTTP referrer 限制；公钥不能代替资料授权。真正的伺服器 secrets 不得出现在前端 bundle。

## 开发与验证

```bash
flutter pub get
flutter analyze
flutter test
dart format lib test

# 无 npm 相依套件、无网路呼叫
node --test scripts/*.test.mjs
npm test --prefix functions-tests
npm test --prefix web-tests

# Python publisher 离线测试（需 uv；已有 .venv 时略过 venv）
uv venv .venv
uv run --no-project --python .venv/bin/python scripts/build_import_prompt_test.py

# Firestore + Auth Emulator（首次需下载依赖与 emulator；需相容 Java）
# 含规则测试，以及安装精灵建立首位管理员的整合测试
npm ci --prefix firestore-tests
npm test --prefix firestore-tests

# 安装精灵的真浏览器 smoke（离线示范，需本机 Chrome；CHROME 可指定执行档）
node scripts/installer-browser-smoke.mjs
```

带设定的本机执行及 release build 见[部署指南](docs/deployment.md)。**Docker/nginx 只是受限的静态前端路线**：需提供 `CHURCH_CONFIG_JSON` build-arg，但不执行 Cloudflare Pages Functions；`calendar`、`photoImport`、`lineNotifications` 必须关闭（否则 build 拒绝），不可当作完整功能的一键部署。

原始码主要位置：

- `lib/features/<feature>/{domain,data,presentation}/`：各功能的 model、repository、UI。
- `lib/core/`：共用设定、型别与 UI 工具。
- `functions/`、`worker/`：Cloudflare API 与共用授权／第三方整合。
- `firestore.rules`、`firestore-tests/`：资料授权模板与 emulator 测试。
- `web/`、`web-tests/`：PWA 资源与快取测试。
- `scripts/`：设定产生、首位管理员 bootstrap 与离线测试。
- `scripts/installer/`：Cloud Shell 安装精灵（核心、各云端 adapter、私人网页）。

协作规范见 [AGENTS.md](AGENTS.md)。欢迎 Issue／PR，但请先移除个资与凭证，不要把正式资料当测试 fixture。

## 授权与素材

MIT 适用于本专案原创程式码与新制中性 PWA 图示，**不会把 Flutter、套件、字型、圣经译本、灵修内容或外部标志全部重新授权为 MIT**。发布时保留第三方 notices；Flutter build 会把它们放在网站的 `assets/NOTICES`。

已核对的本机套件／素材范围与未查实项目见 [第三方授权与素材](docs/third-party-notices.md)。这不是完整的法务稽核或侵权保证。部署者自行加入的教会名称、图示、照片、文章与资料须另有适当权利。
