# 第三方授权与素材

本专案原创程式码的 [MIT License](../LICENSE) 不取代任何第三方授权。重散布 source 或 build 时，应保留原有著作权声明、授权条文及需要附带的 notices。这份说明不是完整法务稽核、授权适用性的保证，也不主张拥有外部内容的权利。

## 已检查的范围

2026-09-24 以当时的 `pubspec.lock`，读取本机 pub cache 对应版本的根 `LICENSE`，并初步分类。这次共找到 **68 个 hosted 套件的 LICENSE**；没有只凭套件名称推定授权。另读取 Flutter `3.41.0` 的根 LICENSE 与 SDK 随附字型授权档。版本升级后须重新核对；完整原文仍以套件内 LICENSE 为准。

直接相依套件（包含开发工具）：

| 套件 | 核对版本 | 根 LICENSE |
|---|---|---|
| `cloud_firestore` | 6.8.0 | BSD-3-Clause |
| `cupertino_icons` | 1.0.9 | MIT；原文署名 Vladimir Kharlampidi |
| `firebase_auth` | 6.5.7 | BSD-3-Clause |
| `firebase_core` | 4.13.0 | BSD-3-Clause |
| `firebase_messaging` | 16.5.0 | BSD-3-Clause |
| `flutter_lints` | 6.0.0 | BSD-3-Clause |
| `http` | 1.6.0 | BSD-3-Clause |
| `intl` | 0.20.3 | BSD-3-Clause |
| `provider` | 6.1.5+1 | MIT；原文署名 Remi Rousselet |
| `shared_preferences` | 2.5.5 | BSD-3-Clause |
| `timezone` | 0.11.1 | BSD-2-Clause |
| `url_launcher` | 6.3.2 | BSD-3-Clause |
| `web` | 1.1.1 | BSD-3-Clause |

其余根 LICENSE 中：

- MIT：`nested` 1.0.0（Remi Rousselet）。
- Apache-2.0：`clock` 1.1.2、`fake_async` 1.3.3、`material_color_utilities` 0.13.0。
- BSD-3-Clause：`_flutterfire_internals`、`async`、`boolean_selector`、`characters`、`cloud_firestore_platform_interface`、`cloud_firestore_web`、`collection`、`ffi`、`file`、`firebase_auth_platform_interface`、`firebase_auth_web`、`firebase_core_platform_interface`、`firebase_core_web`、`firebase_messaging_platform_interface`、`firebase_messaging_web`、`http_parser`、`leak_tracker`、`leak_tracker_flutter_testing`、`leak_tracker_testing`、`lints`、`matcher`、`meta`、`path`、`path_provider_linux`、`path_provider_platform_interface`、`path_provider_windows`、`platform`、`plugin_platform_interface`、`shared_preferences_android`、`shared_preferences_foundation`、`shared_preferences_linux`、`shared_preferences_platform_interface`、`shared_preferences_web`、`shared_preferences_windows`、`source_span`、`stack_trace`、`stream_channel`、`string_scanner`、`term_glyph`、`test_api`、`typed_data`、`url_launcher_android`、`url_launcher_ios`、`url_launcher_linux`、`url_launcher_macos`、`url_launcher_platform_interface`、`url_launcher_web`、`url_launcher_windows`、`vector_math`、`vm_service`、`xdg_directories`。版本记录于 `pubspec.lock`。

以上是根授权档层级的观察，不等于已逐一稽核每个子目录、vendored library、平台原生 SDK 或所有 notices。

## Flutter、字型与建置产物

- Flutter SDK 根授权是 BSD-3-Clause，原文署名 The Flutter Authors。
- 本机 SDK 的 `MaterialIcons_LICENSE.txt` 是 **CC BY 4.0**；不要因程式套件采 BSD/MIT，就宣称所有字型也一样。Material Icons 来源为 Google 的 [Material Design Icons](https://github.com/google/material-design-icons)。Flutter release build 可能做字型子集化，应保留相应 notices。
- 本机 SDK 的 `Roboto_LICENSE.txt`、`RobotoCondensed_LICENSE.txt` 为 Apache-2.0。
- CSS 指定 `Noto Sans TC`、`PingFang TC`、`Microsoft JhengHei` 等名称，不代表本 repo 提供或授权这些字型档。浏览器／Flutter 实际使用的系统字型或下载字型，须按发布环境另行核对。
- App 不在画面上列出授权；第三方 notices 随网站发布。保留 Flutter 的 `LicenseRegistry` 及 build 产生的 `assets/NOTICES.Z` 等授权资源，不要为缩小档案而移除。实际 notices 路径可能随 Flutter 版本调整。
- 本 repo 没有以自己的 MIT 声明复盖 CanvasKit、Dart runtime、Firebase JavaScript SDK 或相关原生 SDK 的授权。

## PWA 图示

目前 `web/favicon.png` 与 `web/icons/Icon-{192,512}.png`、`Icon-maskable-{192,512}.png` 是本专案**自行程式产生**的中性几何图形（3×4 排班格，亮起的格子排成十字架），未使用外部 logo、图片或字型，随本专案 MIT 授权。可重现产生：

```bash
node scripts/generate-neutral-icons.mjs
```

此命令会覆写这五个预设图示。部署者的客制图示请保存在私有设定／素材目录并经 staging 带入，不要先覆写 repo 的预设档。

旧版本中的图示来源及权利未查实，已从目前档案换下；这不会改变 Git 历史中的旧素材，也不构成对旧素材使用／散布权的追认。若要重散布旧版，仍须另行处理。

## 尚未查实／由部署者负责

- npm／Firebase CLI／Wrangler／GitHub Actions 及其传递相依套件的完整授权树，未做逐档稽核。
- Flutter engine、CanvasKit、平台 SDK 及远端载入的 Firebase scripts／中文字型等，未完成全套 notices 的逐项比对。
- 各圣经译本、灵修文章、经文范围 feed、来源网站的再散布及撷取条款。可公开存取不等于可撷取、复制或改作；预设不启用任何来源。
- 教会名称、商标、客制图示、人员照片及个资。没有将任何教会品牌使用权随 MIT 转授；请只加入有权使用的素材。
- Google/Firebase、Cloudflare、Gemini、LINE/n8n 等服务条款、资料处理与地域法规。开源授权不豁免服务商条款、付费义务或个资保护责任。

发布前建议重新核对锁定版本与实际 build，保留完整 notices，确认新增素材的来源与授权；有疑义时寻求适当的法律意见。
