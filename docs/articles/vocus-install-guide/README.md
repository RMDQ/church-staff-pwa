# vocus 安装教学文章

给不会写程式的教会同工看的安装教学，2026-09-28 发布在 vocus：
https://vocus.cc/article/6aba4b3afd89780001a439af

| 档案 | 内容 |
|---|---|
| `article.md` | 文章原稿。`【插入图 NN｜档名】` 是图片位置，下一行 `图说：` 是 caption |
| `images/` | 文章用图。`00-cover.png` 是 vocus 封面，`00-app-overview.png` 是开头主图（也是 Threads 附图） |
| `threads.md` | Threads 宣传贴文（本文、第 2/2 则连结、topic、发文时间） |
| `cover/cover.html` | 封面原始档，用 1200×630 viewport 截图就是 `00-cover.png` |
| `tools/` | 更新 vocus 文章、拍 App 截图用的 script |

截图里的「恩典教会」、王大卫、陈美恩等人名都是示范资料。

## 改文章后更新 vocus

vocus 的编辑器是 Lexical。这些 script 不透过 API，而是用 Chrome DevTools Protocol 操作已登入的 Chrome：先贴 HTML，再把图片标记换成带 caption 的 image node，最后走「调整发布设定」重新发布。

1. Chrome 用 `--remote-debugging-port=9222` 开启，并登入 vocus（Google 帐号 hansli112871114）。
2. `node tools/cdpd.mjs &`：在 127.0.0.1:9333 开一个小型 CDP daemon。第一次连线时 Chrome 会跳「Allow remote debugging?」，要按 Allow。
3. 有新图或换过图：先从 `tools/vocus-images.json` 删掉那张的 key，打开文章编辑页、点进内文，再跑 `python3 tools/upload_images.py`。图片是用贴上 `File` 的方式上传到 vocus CDN，网址会记回 `vocus-images.json`。
4. `python3 tools/build_body.py`：把 `article.md` 转成 HTML，并附上每张图的 caption。
5. `python3 tools/republish.py`：重建内文、清掉「上篇」后重新发布。vocus 每次都会自动把沙龙里的上一篇文章填进「上篇」，所以这一步要清。

`python3 tools/preview.py` 会在这个资料夹产生 `preview.html`（图片内嵌），用来在本机先看排版。这个档已经 gitignore。

## 拍 App 截图（Firebase emulator，全假资料）

不用建立云端资源，也不会用到真实教会的资料：

1. 复制一份 repo，在 `lib/main.dart` 的 `Firebase.initializeApp` 之后加上：
   ```dart
   FirebaseAuth.instance.useAuthEmulator('localhost', 9199);
   FirebaseFirestore.instance.useFirestoreEmulator('localhost', 8181);
   ```
   `default_church_config.dart` 的 `appName` 改成示范教会的名字。要拍行事历的话，把 `features.calendar` 改成 `true`。
2. build：`flutter build web --release --no-web-resources-cdn --dart-define-from-file=fb.json`。`fb.json` 的内容是假的 `FIREBASE_*`，其中 `FIREBASE_PROJECT_ID` 要用 `demo-` 开头。要拍行事历的话，再加上假的 `GOOGLE_CALENDAR_API_KEY` 和 `GOOGLE_CALENDAR_ID`。
3. 起 emulator：`firestore-tests/node_modules/.bin/firebase emulators:start --only auth,firestore --project demo-church`。新版 firebase-tools 需要 Java 21 以上，firestore-tests 里锁的 v14 可以用 Java 17。
4. `python3 -m http.server` 服务 `build/web`，然后跑 `python3 tools/seed.py`，会建立 4 个假帐号、服事表范本和 7 份服事表。密码写在 `staff-pass`，不要 commit。
5. Chrome 用 iPhone 的 device metrics（390×844、DPR 3）加 iPhone Safari UA 开启，用 `meien@example.test` 登入。首页的「加到主画面」卡片按「不用了」后再截图。
6. 行事历：用 CDP `Fetch.enable` 拦截 `*googleapis.com/calendar/*`，再用 `Fetch.fulfillRequest` 回传假活动。
7. 拍完后关掉 emulator 和 server，并删掉那份复制的 repo。
