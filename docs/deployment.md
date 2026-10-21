# 自行部署指南

> 全新教会只需核心功能时，可改用 [Cloud Shell 安装精灵](install-cloud-shell.md)。本指南适用于工程师、既有站台升级、选用整合、自订网域与 GitHub Actions 部署。

这条路线使用各教会自己的 **Firebase Auth／Firestore + Cloudflare Pages／Pages Functions**。本文的 `example.invalid`、`your-project-id`、`AUTH_UID_FROM_CONSOLE` 都是占位值，不是可用的上游服务。以下会连线或写资料的步骤需由有权管理该专案的人确认后执行。

## 0. 前置条件

- Git、Flutter `3.41.0`（Dart SDK 要求见 `pubspec.yaml`）、Node.js 22+。
- Firebase CLI、Google Cloud CLI、Wrangler。CI 的工具／版本以 `.github/workflows/deploy-flutter-pwa.yml` 为准。
- 自己持有的 Google/Firebase 与 Cloudflare 帐号，管理者有权设定 Authentication、Firestore、Pages、网域与 secrets。
- 开启第三方服务前先确认计费／配额与隐私条款。本专案不保证永久免费，不提供代管或客服承诺。

`.env.example` 是设定对照表，**不会自动载入**。server secrets 不得传给 Flutter；`--dart-define` 与 `--dart-define-from-file` 的所有内容最终都可能在浏览器被读取。

## 1. 建立自己的后端

1. 在 Firebase Console 建立专案，新增 Web app，保存它的 Firebase Web config。
2. Authentication → Sign-in method 启用 **Email/Password**；设定自己的正式／预览网域为 authorized domains。本机开发若使用 `localhost`，也确认已允许。
3. 建立 Firestore **`(default)`** 资料库，选择合适区域并以限制存取的模式开始。App 尚未部署完整 rules 与 user profile 前，登入后被拒绝是预期行为；不要先把规则改成公开读写。
4. 在 Cloudflare 建立自己的 Pages 专案。若依本文以 GitHub Actions/Wrangler 部署，避免再开另一条重复的自动 build 部署流程。
5. Production 与 Preview 的资料／凭证分流由部署者决定。至少日历、通知测试目标应与正式环境隔离；需要完全隔离时使用不同 Firebase 专案与对应设定。

## 2. 建立私有设定

```bash
mkdir -p .local
cp config/church.example.json .local/church.json
```

编辑 `.local/church.json`：

- `appName`、`shortName` 设显示名称；`timeZone` 设单一 IANA 时区。
- 每个 `services` 项目有固定 `id`、`label`、`name`、`weekday`（1–7）及 `enabled`。第一版只有**每周固定星期**，不能靠改资料标签实现单周例外。
- **service ID 是永久资料键**。改显示名称只动 `label/name`；停用只动 `enabled:false`，保留项目与 ID，不直接删除。不要为改名让既有 `zones`、`zoneTypes`、服事表变成未知 ID。
- 这里的 `services` 是**预设值**。管理员在 App「我的」→「聚会设定」存过之后，清单改存 Firestore `settings/services`（`services` 清单加上只增不减的 `ids`），App、Firestore rules 的 `serviceTypes()` 与 Worker 都以部署设定加上那份 `ids` 为准。之后再改 `church.json` 的 `services` 只影响还没存过聚会设定的网站；要改名、改星期请在 App 里改。
- 选用功能先维持 `false`；先验证核心登入／服事表，再逐一启用。
- 每日灵粮的 `dataUrl` 是 App 读取 JSON 的网址，`linkUrl` 是点击后的网站；若需 workflow 更新 data 分支，另设 `fetchUrl` 与 `fetchFormat`（`json` 或固定版型 `dailyBibleHtml`）。`fetchUrl` 留空便不抓取，所有日期判定使用同份设定的 `timeZone`。来源 URL 不得含秘密。
- 日历 ID、同工姓名、server secrets 不放这个档案。ChurchConfig 会被编入公开前端及 Worker。

另建立 `.local/firebase-web.json`，只放前端需要的值：

```json
{
  "FIREBASE_API_KEY": "REPLACE_WITH_FIREBASE_WEB_API_KEY",
  "FIREBASE_AUTH_DOMAIN": "your-project-id.firebaseapp.com",
  "FIREBASE_PROJECT_ID": "your-project-id",
  "FIREBASE_STORAGE_BUCKET": "",
  "FIREBASE_MESSAGING_SENDER_ID": "REPLACE_WITH_SENDER_ID",
  "FIREBASE_APP_ID": "REPLACE_WITH_WEB_APP_ID",
  "FIREBASE_MEASUREMENT_ID": "",
  "GOOGLE_CALENDAR_ID": "",
  "GOOGLE_CALENDAR_API_KEY": "",
  "FCM_WEB_VAPID_KEY": ""
}
```

空白选填栏位可依实际 Firebase Web config 补上；其他占位值必须替换。Firebase API key 是前端识别设定，不是管理者凭证；Firestore rules、Auth 与 key 限制才构成对应安全边界。

## 3. 同一份设定产生三端产物

```bash
node scripts/prepare-deployment.mjs \
  --config .local/church.json \
  --out .local/deployment
```

这个动作完全本机处理，**不会部署、不会连 Firebase，也不修改正式资料**。输出包含：

- `.local/deployment/dart-defines.json`：Flutter 的 `CHURCH_CONFIG_JSON`。
- `.local/deployment/worker/generated_config.js` 与 `functions/`：同份设定的 Pages Functions staging。
- `.local/deployment/firestore.rules`、`firebase.json`：依 stable service IDs 产生的规则与部署入口。
- `.local/deployment/church.json`：本次设定副本。
- `.local/deployment/web/`：已套入 appName／shortName／icons 的 `index.html`、`manifest.json`、`firebase-messaging-sw.js` 与需带入的图示资产。

检查输出的 IDs、启用功能及目标专案。不要把 private config 写回 `config/church.example.json`、`worker/generated_config.js` 或 repo 的 `web/`。`build/` 与 `.local/` 已 gitignore；产物可能含教会设定，即使不是金钥也不要随便上传公开附件。

## 4. 先验证并部署生成的 rules

本机离线／emulator 测试：

```bash
flutter pub get
flutter analyze
flutter test
node --test scripts/*.test.mjs
npm test --prefix functions-tests
npm test --prefix web-tests
npm ci --prefix firestore-tests
npm test --prefix firestore-tests
```

Emulator 的第一次执行可能下载工具，需相容 Java。这些测试不等于已验证你的真实 Firebase／Cloudflare／Google Calendar 设定。

登入 Firebase CLI 并明确指定**自己的**专案，审查 `.local/deployment/firestore.rules` 后部署：

```bash
firebase login
PROJECT_ID=your-project-id
firebase deploy --only firestore:rules \
  --config .local/deployment/firebase.json \
  --project "$PROJECT_ID"
```

**不要改用根目录预设 `firestore.rules` 取代生成档。** 新的 stable IDs 若只改 Flutter／Worker 而没有先上对应 rules，存档会被拒绝。更改存取模式时必须同步审查规则；部署流程不会悄悄替你放宽权限。

## 5. 安全建立首位管理员

App 没有「第一个注册者自动变 admin」或公开自助升权入口。先在 Firebase Console → Authentication → Users **手动新增属于首位管理员的 Email/Password 帐号**，核对 email 与 UID，透过适当方式让该管理员取得密码。不要把密码交给脚本或提交到 repo。

先离线预览（不取得 token、不查 Auth、不查／写 Firestore）：

```bash
node scripts/bootstrap-admin.mjs \
  --project your-project-id \
  --uid AUTH_UID_FROM_CONSOLE \
  --name '初始管理员' \
  --username admin \
  --config .local/church.json
```

`--uid` 可换为 `--email admin@example.invalid`。`--name` 必填，`--username` 未指定时使用 name；实际登入仍使用 Auth email，不是 username。未给 `--config` 时 zones 为空，admin 仍有管理权限；给了设定时以启用的 services 同时建立 `zones` 与 `zoneTypes`。

提供 `--config` 时，必须使用与 `prepare-deployment.mjs` 相同的**完整 `church.json`**，会套用相同的 schema、时区、功能、图示与聚会清单验证；不接受只有 `services` 的部分设定档。无效设定会在取得 token 或连线前拒绝，不能靠 bootstrap 绕过部署设定限制。

确认这确实是要授权的本人帐号，而非其他既有帐号后，使用有 `firebaseauth.users.get`／对应 Auth 查询能力与 Firestore 读取／建立权限的管理者 ADC。通常可由专案管理者指派 Firebase Authentication Viewer 与 Cloud Datastore User 等必要 IAM 角色；依实际 IAM policy 采最小权限，使用完移除不再需要的权限。

脚本会把明确指定的 project 同时放入 `x-goog-user-project` 作为 ADC REST 的 quota project；操作者也需在该专案有 `serviceusage.services.use` 权限（例如 Service Usage Consumer），不可默默将其他专案作为配额目标。

```bash
gcloud auth application-default login

node scripts/bootstrap-admin.mjs \
  --project your-project-id \
  --uid AUTH_UID_FROM_CONSOLE \
  --name '初始管理员' \
  --username admin \
  --config .local/church.json \
  --apply \
  --confirm-project your-project-id \
  --confirm-uid AUTH_UID_FROM_CONSOLE
```

这是实际写入命令，**不要在不确定目标时执行**。脚本会显示目标、在指定 project 查既有 Auth user、拒绝停用／UID 不符的帐号，并只建立 `users/{uid}`：

- `id`、`name`、`email`、`username`、`role:'admin'`、`zones`、`zoneTypes`、`groups` 与 App 的 User 格式一致。
- Auth 帐号不存在就失败，**不建立、不删除、不重设任何 Auth 帐号／密码**。
- profile 已存在就拒绝，不升权、不覆写；写入同时有 `currentDocument.exists=false`，即使查询后别人先建立文件也不会覆写。
- email lookup 也必须提供 Console 中核对过的 `--confirm-uid`，避免只凭姓名或 email 误授权。
- IAM/ADC 是管理者权限，能绕过一般 Firestore rules；只在受信任环境使用，不要把此流程搬成公开 API。
- 可改用短期 `GOOGLE_OAUTH_ACCESS_TOKEN`，但不要把 token 写进命令纪录／log／tracked 档案。default dry-run 完全不需要凭证。

脚本的离线测试验证 dry-run、身分核对、拒绝覆写、并发 create precondition 与 API 失败路径。它没有替你验证 live IAM／专案设定；apply 后仍须登入 App 确认。

## 6. 建置与 Pages staging

前端本机开发：

```bash
flutter run -d chrome \
  --dart-define-from-file=.local/deployment/dart-defines.json \
  --dart-define-from-file=.local/firebase-web.json
```

`flutter run` 不会启动 Cloudflare Pages Functions。核心 Firebase 功能可用，但照片／日历写入等 `/api/` 需要对应的 Pages Functions 环境，不能只因前端跑起来就视为完整部署验证。

Release build：

```bash
flutter build web --release --base-href / --no-web-resources-cdn \
  --dart-define-from-file=.local/deployment/dart-defines.json \
  --dart-define-from-file=.local/firebase-web.json
```

接著套入产生的网页 metadata，并只用 staging 的 Functions／Worker 来打包：

```bash
cp -R .local/deployment/web/. build/web/
npx --yes wrangler@4 pages functions build .local/deployment/functions \
  --outdir=build/web/_worker.js
```

`--outdir` 会产生 Pages advanced worker 的 `_worker.js/index.js` 目录；不要改成 `--outfile`，Wrangler 4 的该选项会产生 multipart upload bundle，不是可直接部署的 JavaScript。

这里的 HTML 已将 base href 固定为 `/`，因此本指南限部署在网域根路径。正式上传前还需要与 workflow 相同的版本快取及 FCM 设定注入；不要将未完成注入的 `build/web` 当作完整部署产物。下一节 CI 路线会执行这些步骤，不会把 `.local/deployment` 整个公开成网站。

### 自订图示

预设从 repo 的 `web/` 取中性图示。客制 PNG 请先确认素材权利，将档案留在 gitignored 的 `.local/branding/`，**不用覆写 tracked `web/`**。`icons` 的路径同时代表资产目录内的相对路径与最终网站路径。例如沿用范例路径时：

```text
.local/branding/
├── favicon.png
└── icons/
    ├── Icon-192.png
    ├── Icon-512.png
    ├── Icon-maskable-192.png
    └── Icon-maskable-512.png
```

准备好图示后，用以下命令取代第 3 节的 prepare 命令：

```bash
node scripts/prepare-deployment.mjs \
  --config .local/church.json \
  --assets .local/branding \
  --out .local/deployment
```

产生器只复制 `icons` 指定的 PNG 至 `.local/deployment/web/<相对路径>`，检查档案存在且不允许 realpath／symlink 逃出资产目录。之后仍按照前述 `cp -R .local/deployment/web/. build/web/` 带入，名称、manifest、背景通知图示和实际 PNG 必须来自同一份设定。`--assets` 未指定时就是 `web/`，不会默默下载任何外部图片。

CI 预设不会取得你的私有档案；若用了客制素材，必须在 CI prepare 之前透过自己的资产来源准备同一套档案，或使用下节的固定 Git 版本还原。GitHub Variable `CHURCH_ASSETS_DIR` 指向该 runner 目录（预设 `web`，workflow 会传给 `--assets`）。缺档就应让建置失败，不回退成其他教会图示。本文不提供私有素材储存服务。检查 192/512 尺寸、maskable 安全区及 favicon 后再上线。

#### 选用：从自己的 Git 历史还原图示

**只适合素材已存在于自己的 Git 历史，且你有权使用的情况。** 这不是从其他 repo 搬入私有素材的工具，也不会让曾提交到公开 Git 的图示变成私密。新素材不必为了使用此功能而提交；仍可采前述自行准备 assets 的方式。

在 GitHub Actions Variables 设定：

- `CHURCH_ASSETS_GIT_REF`：操作者明确选定的完整 **40 字元十六进位 commit SHA**，不是分支、tag、`HEAD` 或短 SHA；预设空白，不启用此功能。
- `CHURCH_ASSETS_DIR`：改为 repo 内已 gitignore 的 `.local/` **子目录**，例如 `.local/branding`；启用此功能时不得使用 `web` 或 `.local` 本身。

CI 先验证完整 ChurchConfig 与 SHA 格式，才以 `git fetch --no-tags origin "$CHURCH_ASSETS_GIT_REF"` 取得此 repo 的指定 commit。之后执行只读本机 Git objects 的 helper，固定读取五个来源：

| 固定 Git 路径 | ChurchConfig 目的栏位 |
|---|---|
| `web/favicon.png` | `icons.favicon` |
| `web/icons/Icon-192.png` | `icons.icon192` |
| `web/icons/Icon-512.png` | `icons.icon512` |
| `web/icons/Icon-maskable-192.png` | `icons.maskable192` |
| `web/icons/Icon-maskable-512.png` | `icons.maskable512` |

例如 `icons.icon192` 为 `original/icons/Icon-192.png`，输出就会是 `.local/branding/original/icons/Icon-192.png`，供既有 `prepare-deployment.mjs --assets .local/branding` 使用。**只取图档，不切换程式码版本、不修改 tracked `web/`。** SHA 与目录经环境变数及引用后的参数传入，不当成 shell 程式码。

本机已有该 commit 时，可直接执行相同 helper（下方 SHA 占位值需先替换）：

```bash
ASSET_COMMIT=REPLACE_WITH_FULL_40_HEX_COMMIT_SHA
node scripts/restore-branding-from-git.mjs \
  --config .local/church.json \
  --ref "$ASSET_COMMIT" \
  --out .local/branding
node scripts/prepare-deployment.mjs \
  --config .local/church.json \
  --assets .local/branding \
  --out .local/deployment
```

Helper 自己**不 fetch、不上传、不读凭证**，不接受其他 revision 表达式或任意来源路径。它先验证全部 PNG 的结构、CRC、解压大小及尺寸（192/512 对应图示；favicon 为 16–256 正方形，每档最多 4 MiB），再写入。缺档、坏档、非 commit、非 ignored 目录或 symlink／路径越界皆拒绝；既有档案内容不同时拒绝覆写，相同则可重复执行。要更换来源且内容不同，先自行核对并改用新的 `.local/` 子目录，勿把错误当成可忽略的警告。

`CHURCH_ASSETS_GIT_REF` 留空时，CI 不 fetch 图示、不执行还原 helper，维持原本的中性／自行准备 assets 流程。

Docker 的资产来源目前固定为 build context 中的 `web/`，且 `.local/` 已被 `.dockerignore` 排除；`CHURCH_ASSETS_DIR` 不是 Docker 的私有 context 功能。若使用受限 Docker 路线且需要客制图示，可自行将有权使用的 PNG 放入 gitignored `web/private-icons/`，再把 `icons` 改为该相对路径；不要提交这些教会素材。

## 7. GitHub Actions 与 Cloudflare

`.github/workflows/deploy-flutter-pwa.yml` 是标准 release 路线：`main`／`dev` push 或手动触发会执行；**没有 `DEPLOY_ENABLED` 这类额外开关**。Fork 后先确认 Actions 是否允许执行，完成自己的设定再触发。`main` 对应正式、`dev` 对应预览；缺少必要设定时 fail-fast，不拿中性设定盖既有站台。

GitHub Settings → Secrets and variables → Actions：

- Variable `CLOUDFLARE_PAGES_PROJECT`；Secrets `CLOUDFLARE_ACCOUNT_ID`、`CLOUDFLARE_API_TOKEN`（最小所需 Pages 权限）。名称及 Secret／Variable 位置需与 workflow 一致。
- Secret 或 Variable `CHURCH_CONFIG_JSON`：自己的 `.local/church.json` 全文；secret 优先。虽不是 server secret，仍不要把真实部署档提交到公开 source。
- 选填 Variable `CHURCH_ASSETS_DIR`：runner 上已准备好的 PNG 目录，预设 `web`。
- 选填 Variable `CHURCH_ASSETS_GIT_REF`：依前节从自己的 Git 历史还原五张图示的完整 40hex commit SHA；启用时 `CHURCH_ASSETS_DIR` 必须是 ignored `.local/` 子目录。
- Firebase Web 栏位；选用功能启用才加 Calendar API key／calendar ID／FCM VAPID 公钥。
- Production／Preview 的执行期设定须**另外**放 Cloudflare，不是只填 build 用 GitHub 变数。

Cloudflare runtime 最小必需 `FIREBASE_PROJECT_ID`。选用整合再补：

| 功能 | Cloudflare runtime 设定 |
|---|---|
| Google Calendar 写入 | `GOOGLE_CALENDAR_ID`、Secret `GOOGLE_SERVICE_ACCOUNT_JSON` |
| 照片辨识 | Secret `GEMINI_API_KEY`，选填 `GEMINI_MODEL` |
| LINE/n8n webhook | `NOTIFY_WEBHOOK_URL`、Secret `NOTIFY_WEBHOOK_SECRET` |
| 同工登入帳號的新增／刪除 | Secret `ACCOUNT_ADMIN_KEY` |

`ACCOUNT_ADMIN_KEY` 是只授予 `roles/firebaseauth.admin` 的 service account key（JSON 全文），讓 `/api/accounts` 替管理員建立、刪除同工的 Firebase Auth 帳號；不要和行事曆那把共用。沒設定時 App 改在瀏覽器建立帳號，刪除同工只刪 `users/{uid}`，登入帳號要到 Firebase Console 手動刪。安裝精靈裝的網站會自動設定（見[安裝精靈說明](install-cloud-shell.md#同工帳號管理)）。

一般不要设定 runtime `CHURCH_CONFIG_JSON` binding；Worker 使用 staging 内的产生设定。如果设定了 binding，**任何值与 staging 不一致都会拒绝**，不只是 service IDs，以免名称、时区或功能开关与 Flutter／rules 漂移。修改 secrets 后依 Cloudflare 的设定生效方式重新部署，并分别验证 Production／Preview。

`scripts/push-calendar-secrets.sh` 只设定 Production，且必须指定自己的 `CLOUDFLARE_PAGES_PROJECT`。Wrangler Pages secret put 没有可用的 `--env preview`；Preview 请用 Cloudflare Dashboard 或正式 REST API 另行设定，不要误以为跑一次脚本就两边都有。

行事历写入还需要 Google Calendar API 已启用，并把目标日历分享给 service account（变更活动）。那把 service account key 仅给日历写入使用，不能放进 `.local/firebase-web.json`。公用日历的读取 key 应限制 HTTP referrers 与 Calendar API 用途。

选用的 `scripts/verify-calendar-writer.mjs` 是 **live 检查，不是离线测试**：会使用真实 service account 在目标日历建立一笔远期活动、读回、再删除；清理失败需人工删除。只有在有权且已确认测试目标时才执行。它现在读取 prepare 产生的 Worker，因此必须先 prepare；预设输出目录是 `.local/deployment`，另有 `CHURCH_DEPLOYMENT_DIR` 可指定目录，`CHURCH_CONFIG_FILE` 则指定同一份设定。不要在文件验证或 CI 离线测试中自动执行它。

### 照片汇入首次初始化

**只有 `photoImport=true` 与 `GEMINI_API_KEY` 还不能辨识。** 新资料库或新加入的聚会没有 `settings/import_prompts` 对应栏位时，API 会回复「辨识设定还没建立」。先保持照片功能关闭，在确认过的测试专案完成以下流程，再依自己的变更程序套用正式环境。

1. 管理员登入 App，在服事表编辑模式的「服事项目设定」为每个要辨识的聚会新增项目并储存，建立 `settings/roster_templates`。也开启「事件选项设定」并储存：没有特殊活动可以留空，但产生脚本需要 `settings/event_options` 文件存在。确认 `users` 至少已有具姓名的管理员／同工 profile；完全没有姓名时脚本会中止。
2. 视表格版面准备 gitignored `.local/import-rules.json`，每个顶层键必须是 `church.json` 的 `services[].id`。`layoutRules`、`extraRoleRules`、`nicknames`、`teamRules` 的格式及范例见[模板文件](roster-import-prompt.template.md#各崇拜的差异怎么设定)。没有特殊规则可以省略档案；缺 `layoutRules` 会警告，表示尚未指定版面，不代表任意表格都能正确辨识。不要把真实绰号、名单或预览产物提交到 repo。
3. 确认本机安装 `uv`、Python 3.10+、Node.js 与 Google Cloud CLI。脚本会先用目前 `gcloud` 使用者取得 access token，失败才退回 ADC；必须核对实际登入帐号及目标专案。该帐号需要读取目标 Firestore 的 `users`／`settings`，发布时另需建立／更新 `settings/import_prompts` 的 IAM 权限（由专案管理者依最小权限授予，例如适用的 Cloud Datastore User）。**App 的 admin 身分不等于 gcloud 的 IAM 权限；这条管理脚本路径也不受 App 的 Firestore rules 限制。** 不需把 Google Calendar service account key 交给此脚本。

下列初始化环境以 repo 根目录执行；替换 project 与 service ID，`CHURCH_CONFIG_FILE` 必须指向 prepare-deployment 使用的**同一份**设定：

```bash
# 已有 .venv 时略过这行；Python 脚本只用标准函式库
uv venv .venv
export CHURCH_CONFIG_FILE="$PWD/.local/church.json"
export FIREBASE_PROJECT_ID=your-project-id
SERVICE_ID=sundayService # 替换成自己设定中要辨识的 stable ID
```

**以下生成命令会读取真实 Firestore 及取得 token，不是离线 dry-run**，但不写入远端，也不呼叫 Gemini。由有权操作者确认读取对象后才执行：

```bash
uv run --no-project --python .venv/bin/python \
  scripts/build-import-prompt.py "$SERVICE_ID"
```

检查 `.local/roster-import-prompt.<SERVICE_ID>.md` 的日期、项目、版面与姓名；它含同工资料，只供私下检查。脚本同时检查模板栏位是否和 Worker 相符。若输出「没有服事项目，跳过」就还没有生成该聚会模板，先回 App 完成设定。省略 service ID 会处理设定中的所有聚会；不会自动排除停用的聚会，因此首次设定建议逐一指定。

**只有内容、专案、帐号权限与正式写入都已获确认后，才执行 `--publish`：它会重新读取资料，实际建立／更新 `settings/import_prompts`，不是预览，也没有互动确认提示。不要放进一般离线测试或自动执行。** 已有模板时先备份，单次只更新这次指定的 service ID 栏位，其他聚会模板保留；发布的是保留 `{{ROLES}}` 等即时栏位的模板，不是把本机的完整姓名预览原封不动上传。

```bash
uv run --no-project --python .venv/bin/python \
  scripts/build-import-prompt.py "$SERVICE_ID" --publish
```

每个要辨识的聚会都完成后，设定 Cloudflare runtime Secret `GEMINI_API_KEY`，将同份 `church.json` 的 `features.photoImport` 设为 `true`，重新 prepare、建置及部署对应前后端。在已授权的测试资料上操作「汇入服事表 → 从照片辨识」，校对回传 JSON 再决定是否汇入；这会传送照片／名单给 Gemini 并使用配额，不属于离线验证。新增聚会、修改私有规则或模板本文要重新发布该聚会模板；只改既有聚会的同工、项目或事件名单时，Worker 会即时读取，不必重发。照片功能关闭时仍可手动贴 JSON。

Publisher 的安全离线回归可用 `uv run --no-project --python .venv/bin/python scripts/build_import_prompt_test.py`；一般只 mock HTTP，不读私有设定或凭证。若另设 `FIRESTORE_EMULATOR_HOST`，只接受 loopback host，额外在固定 `demo-prompt-mask` 专案测试含连字号 ID 的部分更新；务必使用专门的本机 emulator，不要指向共享测试资料。这些测试不证明真实 IAM 或 Gemini 辨识品质。

## 8. 上线检查

- 未登入／仅有 Auth 帐号但无 user profile 者不能读取受保护资料；非 admin 不能修改角色／groups。
- 管理员登入后可管理使用者及正确的聚会种类；服事表编辑者只能修改被授权牧区。
- 跨日、跨月与浏览器时区不同时，使用的日期仍符合教会时区；DST 区域另测夏令时间边界。
- 未启用的行事历、照片、通知及灵粮入口不造成 API 呼叫或错误。
- 启用的整合用测试帐号／测试日历逐一验证，确认 Preview 不会发到正式通知目标。
- title、载入画面、manifest、加入主画面图示与登入后名称一致。保留 Flutter 第三方 notices 及授权入口。
- 开启过旧 PWA 的装置也能更新；`cache_sw.js` 中没有 `__BUILD_VERSION__`／`__VENDOR_VERSION__` 未替换值。启用推播时，messaging SW 没有 Firebase placeholders。
- 在公开 diff／artifact 检查中没有同工姓名、真实日历 ID、key、service account JSON、Webhook secret 或私有设定。
- 建立自己的 Firestore 备份、帐号停用及凭证轮替流程。不要用重设规则为公开读写来解决权限错误。

## 既有部署升级：先设定、再切换

**不要把中性范例直接推到既有正式站。** 升级前先从既有部署设定重建自己的私有 `church.json`，核对原 appName、service IDs、时区、功能开关、灵粮／日历／图示设定与 server secrets；本 repo 不会自动读上游环境来帮你猜。

1. 备份既有 Firestore，保留目前可回复的部署版本及 rules。
2. 核对 Firestore 里实际使用的 stable service IDs、`zones`、`zoneTypes` 与新设定一致；不能以改 config 的方式偷偷迁移正式资料。
3. 若有旧资料缺 `zoneTypes`，先在隔离环境规划与验证迁移，再另行授权执行；不要直接复制旧 README 的 backfill 命令去动正式资料。
4. 先在独立 preview／测试专案用相同生成流程验证。审查新的 rules 是否与仍在使用的旧 App 相容。
5. 经确认后依序部署**生成 rules → 对应 Worker／Flutter／web staging**。需要无中断过渡时先做相容规则或维护窗口，不可先上不相容规则造成既有使用者全面锁住。
6. 首位管理员脚本只给新 profile 用；既有使用者若需权限调整，由已有管理员处理，不使用 bootstrap 强制覆写。
7. 确认实际装置更新成功后再停用旧站；停用 service 仍保留原 ID。设定产生器本身不做 Firestore 资料迁移、删除或自动修正。
8. 第一次升级先保留原星期与时区，确认所有管理员装置更新后才调整排程设定。新版会在 transaction 内读取同周七个日期，避免不同星期设定的新版客户端同时重复补表；旧的固定三聚会版本没有这个防护，不能混用它来变更排程。既有排表不会因改设定而搬动。

## 部署界线

- Docker／nginx 只提供受限的静态前端。它也需要 `CHURCH_CONFIG_JSON` build-arg（compose 读同名环境变数），但**不执行 Pages Functions**；`calendar`、`photoImport`、`lineNotifications` 必须关闭，否则 build 拒绝。使用这些整合请走 Cloudflare，不把 Docker 说成完整功能的一键部署。
- 本次 repo 内的离线测试、emulator 测试与 web build 只能证明对应程式层面的结果，不能取代你的真实 IAM、DNS、日历 ACL、FCM／LINE 收件或供应商配额测试。
- [第三方授权与素材](third-party-notices.md) 记录目前已知范围及未查实项；部署者自行加入的素材、同工资料与外部内容仍须有适当权利。
