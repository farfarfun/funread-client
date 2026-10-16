# funread-client

[funread](https://github.com/farfarfun/funread) 的 Flutter 客户端。

funread 是一个自托管的小说 / RSS 阅读器。这个仓库是它的原生客户端，和已有的
`funread-web`（Vue 3）**并行存在**：web 端仍然是桌面浏览器上的主力形态，
这边解决的是手机、平板和桌面应用。两边共用同一套 REST 契约
（`funread-api` 的 `/api/v1`）。

> **当前状态：阅读链路可用。** 登录 → 搜索 → 选源 → 详情 / 目录 → 正文 →
> 翻章 → 进度回写 → 加入 / 移出书架，整条链跑得通。
> 正文是**可滚动的纯文本**；分页排版、字号设置、夜间模式、换源 UI、
> 离线缓存都还没做（见「下一阶段」）。

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
      book_detail_controller.dart  书架记录 → 详情 → 目录
      reader_controller.dart    正文 / 翻章 / 进度回写（含 ReadingPosition）
    ui/
      login_screen.dart         服务器地址 + 账号密码
      search_screen.dart        搜索框 + 结果列表 + 搜索统计
      book_sheet.dart           结果详情面板，同时是**选源**的地方
      book_detail_screen.dart   封面 / 简介 / 目录 / 加入书架 / 开始阅读
      reader_screen.dart        正文（可滚动纯文本）+ 翻章 + 目录抽屉
      book_cover.dart           封面（必带 errorBuilder）
test/                           模型解析 / API 契约 / 登录闸门 / 阅读链路
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

六个平台目录都已经在版本库里（由 `.github/workflows/scaffold.yml` 生成），
`pubspec.lock` 也已入库。Dart 代码本身没有任何平台特定分支，
只有 `cookie_store_*.dart` 按 io / web 分了两套。

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

没引 provider / riverpod / get_it。长生命周期的对象只有两个（`FunreadApi`、
`AuthController`），其余控制器都是**每屏一个、跟着屏幕生灭**
（`BookSearchController` / `BookDetailController` / `ReaderController`），
在 `didChangeDependencies` 里建、在 `dispose` 里销。
多一个状态管理依赖就多一层以后要拆的东西。

路由：**登录闸门用状态，阅读链路用 Navigator 栈**，两者不是一回事。
`AuthGate` 看 `AuthStage` 决定渲染登录页还是主界面 —— 那是互斥关系，用路由
表达就要在每个 401 之后手动 pop 回登录页。而搜索 → 详情 → 正文是真正的栈：
读完一章要能原路退回那次搜索的结果上。所以这条链直接 `Navigator.push`，
没有引路由库 —— 引了反而要把 `BookRef` 序列化进 URL，而对象导航恰好让
`variables` 这种不该给用户看见的字段留在内存里。

### 阅读链路：详情页把 BookInfo 和目录**传给**正文页

funread-web 每进一次正文页都要重跑 `/reader/book` + `/reader/toc`，因为它的
页面状态只能从 URL 恢复。Flutter 没有这个约束，所以 `ReaderScreen` 的入参就是
详情页已经拿到的 `BookInfo` + `List<Chapter>`。省掉的不只是两次请求（目录那步
可能要 90 秒）—— 更重要的是 `BookInfo.variables` 和 `Chapter.variables` 原样
挂在对象上，**结构上就丢不掉**，而丢掉它的表现是静默读到空正文。

### 进度：字符偏移，不是滚动像素

`ReadingPosition`（`state/reader_controller.dart`）按「已读字符 / 总字符」在
滚动像素和 `char_offset` 之间换算。像素值和字号、行距、屏幕宽度绑死，换台设备
就是个随机数；字符偏移不精确（段落长短不均，落点会差几行）但稳定。

回写**节流 3 秒 + 翻章前和离开页面时各补一次**：不节流会在滚动时每帧打库，
只节流不补写则会丢掉最后一段 —— 读者往往读到一半就直接切走。
书不在书架时一次都不发：那种情况后端会 404，而试读本来就不需要进度。

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

- 应用图标是占位的纯色方块，不是设计稿。
- Android 开了 `usesCleartextTraffic`：自托管实例绝大多数跑在局域网明文
  http 上，不开就是「连不上且没有任何提示」。代价是同网段可嗅探，这和后端
  `secure=False` 的 cookie 是同一个取舍、同一个前提 —— **不要把实例直接挂到公网**。
- `dart format` 没有进 CI 门禁（建仓库时没法在本地跑一遍确认）。提交前请自己跑。

## CI

`.github/workflows/ci.yml` 跑四个 job，缺一不可 —— 开发机上没有 Flutter SDK，
CI 是唯一的编译验证手段：

| job | 内容 |
| --- | --- |
| `analyze + test` | `flutter analyze`（info 级别也算失败）+ `flutter test` |
| `build web` | `flutter build web --release`，产物上传为 artifact |
| `build apk (debug)` | `flutter build apk --debug`，产物上传为 artifact |
| `build linux` | `flutter build linux --release`（要先装 GTK / CMake 那套） |

macOS / iOS 的工程文件在版本库里，但**没有 CI 验证**（macos runner 计费是
ubuntu 的 10 倍）。它们算「生成了但未经编译验证」。

Flutter 版本固定在 `FLUTTER_VERSION`，不跟 `channel: stable` 漂 ——
小版本会改 lint 的严格程度和 AGP 的兼容区间，不固定的话 CI 会在没人改代码的
时候自己变红。升级 Flutter 时，`android/settings.gradle.kts` 里的
AGP / Kotlin 版本和 `gradle-wrapper.properties` 里的 Gradle 版本要一起对，
它们来自同一版 `flutter_tools/lib/src/android/gradle_utils.dart`。

## 下一阶段

这一版做完的：详情 / 目录 / 正文 / 翻章 / 进度 / 加入移出书架。
刻意没做、以及做的时候留下的坑：

- **换源 UI。** 搜索结果里的 `sources` 是多个，哪个源真能读出正文要到目录 /
  正文那步才知道。现在的做法是「回搜索结果换一个源重进详情页」，够用但笨。
  正经的入口是 `GET /reader/sources` —— 那是一次**实时聚合搜索**，很慢，
  而且它按书名松匹配，`exact=false` 的候选**不能隐藏**（作者名写法差异很常见，
  而那些源往往恰恰是还活着的）。换完走 `POST /shelf/{book_key}/source`，
  它会告诉你进度被重定位到哪一章以及定位方式（`position` 表示按比例估的，
  **必然不准**，要提示用户确认）。换源之后整条链都要用新源重算：
  `BookInfo.variables`、目录序号、正文，一个都不能沿用。
- **离线缓存。** `/reader/content` 带上 `book_key` 已经会走**服务端**那层缓存
  （客户端现在就带着），但那只能救「断外网不断内网」。真飞行模式要把章节存在
  这台设备上，Flutter 这边得上 drift / sqflite。后端的批量下载是 202 +
  `task_id` 轮询，单次最多 200 章，长目录要客户端自己切片。
- **排版。** 分页 / 滚动两种模式、字号行距、夜间模式、翻页手势、长章节的性能。
  现在是一个 `SingleChildScrollView` 套 `Column` 把所有段落一次性建出来 ——
  几万字的章节上这会掉帧，换成 `ListView.builder` 之前别指望它顺。
  注意分页正文不用客户端拼：后端已经把分页抓取的多段合并好了（`pages` 被
  刻意省掉）。
- **目录搜索 / 倒序。** 几千章的书里靠滚动找章节是能用但难用。
- **多设备进度冲突。** 进度是一人一本书**一条**记录、后写覆盖先写。
  现在没有任何处理：一个开着没关的页面回头滚一下，就会把手机上读到的新进度
  盖掉。funread-web 的做法是回到页面时比一次服务端进度、**只问不跳**
  （自动跳转会在「我就是想回头重读」时把人强行拽走）。
- 等后端的设备 token 落地，顺手把认证层换掉（见上）。
