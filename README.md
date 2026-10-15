# funread-client

[funread](https://github.com/farfarfun/funread) 的 Flutter 客户端。

funread 是一个自托管的小说 / RSS 阅读器。这个仓库是它的原生客户端，和已有的
`funread-web`（Vue 3）**并行存在**：web 端仍然是桌面浏览器上的主力形态，
这边解决的是手机、平板和桌面应用。两边共用同一套 REST 契约
（`funread-api` 的 `/api/v1`）。

> **当前状态：骨架。** 能跑通的只有「登录 → 搜索 → 看结果列表」。
> 阅读器（详情 / 目录 / 正文 / 换源 / 进度 / 离线缓存）是下一阶段。

## 目录结构

```
lib/
  main.dart                     入口，只有 runApp
  src/
    app.dart                    MaterialApp + AuthGate（按会话状态决定渲染哪一屏）
    app_scope.dart              AppServices + InheritedWidget
    config/
      app_config.dart           编译期常量、默认 API 基址、搜索超时
      settings_store.dart       后端地址的本地持久化
    api/
      funread_api.dart          界面唯一入口，按后端 router 分成三组
      api_client.dart           dio 封装：基址、凭证、超时、错误翻译
      api_exception.dart        ApiException / UnauthorizedException / ForbiddenException
      auth_api.dart             /auth/me /login /register /logout /accounts
      shelf_api.dart            /shelf 列表、分组、增删、进度
      reader_api.dart           /reader/search /book /toc /content
      cookie_store*.dart        会话凭证的平台分支（条件导入，见下）
    models/                     手写 fromJson，对应后端的 response_model
    state/
      auth_controller.dart      会话状态机
      book_search_controller.dart
    ui/
      login_screen.dart         服务器地址 + 账号密码
      search_screen.dart        搜索框 + 结果列表 + 搜索统计
      book_sheet.dart           结果详情面板
test/                           模型解析 / API 契约 / 登录闸门
android/  web/                  已提交并在 CI 上验证编译
```

## 跑起来

本机需要 Flutter **3.47.7**（CI 固定在这个版本上）。

```bash
flutter pub get

# 默认连 http://127.0.0.1:18811
flutter run

# 指定后端（也可以在登录页里直接填）
flutter run --dart-define=FUNREAD_API_BASE=http://nas.lan:18811

flutter analyze
flutter test
flutter build apk --debug
flutter build web --release
```

### 其它平台目录

仓库里只提交了 `android/` 和 `web/`，因为只有这两个能在 CI 上被真正编译验证。
iOS / macOS 的 Xcode 工程和 Linux / Windows 的 CMake 工程请自己生成一次：

```bash
flutter create --platforms=ios,macos,linux,windows \
  --org com.farfarfun --project-name funread_client .
```

这条命令是幂等的补齐操作，不会动 `lib/`、`test/`、`pubspec.yaml`。
生成之后请检查并提交；Dart 代码本身没有任何平台特定分支，只有
`cookie_store_*.dart` 按 io / web 分了两套。

## 架构上的几个决定

### 认证：暂时用 cookie jar，这是临时方案

后端现在只发 `HttpOnly; SameSite=Lax` 的 session cookie。浏览器会自动管好它，
原生端不会，所以 io 平台上自己挂了一个 `PersistCookieJar` 落盘
（`dio_cookie_manager` + `cookie_jar` + `path_provider`）。

cookie 对原生客户端是个糟糕的载体：没有过期协商、多账号要自己隔离 jar、
撤销只能等 TTL 到期（丢手机之后没法远程下线）。**后端已经计划加设备 token
（Bearer），但还没做。** 等它上线之后，收口动作集中在
`lib/src/api/cookie_store*.dart`：删掉两个 cookie 依赖，换成一个塞
`Authorization` 头的拦截器，token 存 `flutter_secure_storage`。
除了这组文件，其它地方都不知道凭证长什么样。

web 上则完全相反 —— 浏览器不允许 JS 设置 `Cookie` 头，cookie 管理器是空转。
那边改成打开 `withCredentials`，并假定**同源部署**（反代把 `/api` 转给后端）。
跨源调试要后端自己配 CORS，且 `Access-Control-Allow-Origin` 不能是 `*`。

### 模型：手写 fromJson，不用 json_serializable

codegen 只有两种落法：把 `.g.dart` 提交进仓库（review 噪音，手改必然漂移），
或者在 CI 里多跑一遍 build_runner（这个仓库的 CI 是唯一的编译验证手段，
不该再加版本耦合）。当前只有七个模型，手写的总成本更低。
所有 `fromJson` 都**不抛异常**，缺字段退化成零值 —— 后端加个字段不该让客户端白屏。

`BookInfo` 和 `Chapter` 额外有 `toJson`，而且必须是 `fromJson` 的精确逆：
书源规则会在详情页 `@put` 变量、在目录页和正文页 `@get` 取回来，
中途丢掉 `variables` 的表现是**静默读到空目录或空正文**，不是报错。

### 状态管理：ChangeNotifier + 一个 InheritedWidget

没引 provider / riverpod / get_it。这一版只有两个长生命周期对象，
多一个状态管理依赖就多一层以后要拆的东西。页面多起来之后再说。

同理没有引路由：两屏之间是**状态驱动**的互斥关系（`AuthGate` 看 `AuthStage`），
不是导航关系。用路由表达的话，每个 401 之后都要手动 pop 回登录页。

### 搜索统计要显示出来

`/reader/search` 回的那组 `sources_tried / sources_ok / js_skipped / stopped_by`
不是调试信息。书源池里实跑可用率只有个位数百分比，「这本书没有」和
「这轮试的源全挂了」是两件完全不同的事；不把它说出来，每次空结果都会被
当成客户端的 bug。结果列表底部那行小字和空态文案都是为这个服务的。

### 错误处理

界面永远见不到 `DioException`。所有网络异常在 `ApiClient` 里翻成
`ApiException` 树，`detail` 优先取 FastAPI 的（422 的数组形态也会拼成一句人话）。
401 单独一个类型，因为处理方式不是弹错误框，而是把会话打回未登录。

## 已知问题

### Web 端中文字体要下载约 6.3 MB

Flutter Web 默认用 CanvasKit 渲染，**不回退到系统字体**。页面上出现中文时，
引擎会从 `fonts.gstatic.com` 拉 Noto Sans SC（约 6.3 MB），首屏因此会
先白一阵、再突然出字；内网 / 离线部署下则是永远出不来。

这一版不解决。可选的出路，按代价从低到高：

1. 自带一份子集化的中文字体打进 assets，并在 `ThemeData.fontFamily` 里指定 ——
   体积可控（常用字集 1～2 MB），但要加一步字体子集化的构建；
2. 自建字体镜像，把 `fontFallbackBaseUrl` 指到内网，至少让离线部署能出字；
3. 换 HTML/DOM 渲染路径（如果目标 Flutter 版本还提供）—— 用浏览器自己的字体，
   但文本排版会和原生端分叉。

### 其它

- `pubspec.lock` 没有提交（建仓库时本机没有 Flutter SDK，生成不出可信的锁文件）。
  第一个装了 SDK 的人请跑 `flutter pub get`，把 `.gitignore` 里那一行删掉，
  再把 lock 提交进来 —— 应用仓库是要锁依赖的。
- 应用图标是占位的纯色方块，不是设计稿。
- Android 开了 `usesCleartextTraffic`：自托管实例绝大多数跑在局域网明文
  http 上，不开就是「连不上且没有任何提示」。代价是同网段可嗅探，这和后端
  `secure=False` 的 cookie 是同一个取舍、同一个前提 —— **不要把实例直接挂到公网**。
- `dart format` 没有进 CI 门禁（建仓库时没法在本地跑一遍确认）。提交前请自己跑。

## CI

`.github/workflows/ci.yml` 跑三个 job，缺一不可：

| job | 内容 |
| --- | --- |
| `analyze + test` | `flutter analyze`（info 级别也算失败）+ `flutter test` |
| `build web` | `flutter build web --release`，产物上传为 artifact |
| `build apk (debug)` | `flutter build apk --debug`，产物上传为 artifact |

Flutter 版本固定在 `FLUTTER_VERSION`，不跟 `channel: stable` 漂 ——
小版本会改 lint 的严格程度和 AGP 的兼容区间，不固定的话 CI 会在没人改代码的
时候自己变红。升级 Flutter 时，`android/settings.gradle.kts` 里的
AGP / Kotlin 版本和 `gradle-wrapper.properties` 里的 Gradle 版本要一起对，
它们来自同一版 `flutter_tools/lib/src/android/gradle_utils.dart`。

## 下一阶段（阅读器）

要动的地方和已知的坑：

- **`variables` 必须端到端传下去。** 搜索结果 → `/reader/book` → `/reader/toc`
  → `/reader/content`，中间任何一步丢掉 `BookInfo.variables` 或
  `Chapter.variables`，带变量的源都会静默读到空。
- **搜索结果里的 `sources` 是多个。** 哪个源真能读出正文，要到目录 / 正文那步才
  知道。详情页需要「换源」入口（`GET /reader/sources` 是一次**实时聚合搜索**，
  很慢，而且它按书名松匹配，`exact=false` 的候选**不能隐藏** ——
  作者名写法差异很常见，而那些源往往恰恰是还活着的）。
- **进度回写** 走 `PUT /shelf/{book_key}/progress`，返回 204。换源之后用
  `POST /shelf/{book_key}/source`，它会告诉你进度被重定位到哪一章以及定位方式
  （`position` 表示按比例估的，**必然不准**，要提示用户确认）。
- **离线缓存**：`/reader/content` 带上 `book_key` 才会走缓存。下载是 202 +
  `task_id` 轮询，单次最多 200 章，长目录要客户端自己切片。
- **分页正文**：后端已经把分页抓取的多段正文合并好了（`pages` 字段被刻意
  省掉），客户端不需要再拼。
- **阅读器的排版**才是真正的工作量：分页 / 滚动两种模式、字号行距、夜间模式、
  翻页手势、长章节的性能。建议先用可滚动的纯文本把链路跑通，
  再单独做排版。
- 等后端的设备 token 落地，顺手把认证层换掉（见上）。
