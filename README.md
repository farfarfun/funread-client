# funread-client

[funread](https://github.com/farfarfun/funread) 的 Flutter 客户端。

funread 是一个自托管的小说 / RSS 阅读器。这个仓库是它的原生客户端，和已有的
`funread-web`（Vue 3）**并行存在**：web 端仍然是桌面浏览器上的主力形态，
这边解决的是手机、平板和桌面应用。两边共用同一套 REST 契约
（`funread-api` 的 `/api/v1`）。

> **当前状态：阅读链路可用，正文可配置。** 登录 → 搜索 → 选源 → 详情 / 目录
> → 正文 → 翻章 → 进度回写 → 加入 / 移出书架，整条链跑得通。正文是滚动式的，
> 字号 / 行距 / 页边距 / 主题可调，长章节按需构建，多设备进度冲突会**问**
> 而不是悄悄覆盖。分页排版（模拟翻书）刻意不做；换源 UI、离线缓存还没做
> （见「下一阶段」）。

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
      paragraph.dart            正文切段，每段记住自己在原文里的起点
      reader_settings.dart      排版设置的值类型（只存本地）
    state/
      auth_controller.dart      会话状态机
      book_search_controller.dart
      book_detail_controller.dart  书架记录 → 详情 → 目录
      reader_controller.dart    正文 / 翻章 / 进度回写 / 多设备进度冲突
      reader_settings_controller.dart  排版设置 + 落盘时机
    ui/
      login_screen.dart         服务器地址 + 账号密码
      search_screen.dart        搜索框 + 结果列表 + 搜索统计
      book_sheet.dart           结果详情面板，同时是**选源**的地方
      book_detail_screen.dart   封面 / 简介 / 目录 / 加入书架 / 开始阅读
      reader_screen.dart        正文 + 翻章 + 目录抽屉 + 翻页手势 / 键盘
      chapter_layout.dart       每段高度的实测结果，字符 ↔ 像素换算
      reader_palette.dart       日间 / 护眼 / 夜间三组配色
      reader_settings_sheet.dart  排版面板
      book_cover.dart           封面（必带 errorBuilder）
test/                           模型解析 / API 契约 / 登录闸门 / 阅读链路 /
                                换算精度 / 懒构建 / 进度冲突 / 排版设置
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

### 进度：字符偏移，不是滚动像素；而且是**逐段**换算

存 `char_offset` 的理由不变：像素值和字号、行距、屏幕宽度绑死，换台设备就是个
随机数。但换算方式换了一次，原因在下一节 —— 正文改成懒构建之后，
「已读字符 / 总字符 × 可滚高度」这个比例法的两个前提都不成立了。

现在由 `ui/chapter_layout.dart` 负责：开章时把每一段的高度量出来，
字符 ↔ 像素**先定位到哪一段、再在段内插值**。比例法等于假设字符在章内均匀
分布，而对话多的章节里「四个字一段」和「四百字一段」交替出现，
四个字那段照样占满一行 —— 实测差出十几行，表现是「续读跳到了不相干的地方」。

回写**节流 3 秒 + 翻章前、切后台、离开页面各补一次**：不节流会在滚动时每帧
打库，只节流不补写则会丢掉最后一段 —— 读者往往读到一半就直接切走，
手机上进程还可能在后台被系统回收，`dispose` 不一定跑得到。
书不在书架时一次都不发：那种情况后端会 404，而试读本来就不需要进度。

### 长章节：先量后建，不是直接换 ListView.builder

几万字的章节原来是一个 `SingleChildScrollView` 套 `Column`，所有段落一次性
建出来。换成 `ListView.builder` 是对的，但**只换 widget 会把进度带坏**：
没建出来的 item 没有高度，`maxScrollExtent` 只能按已经建出来的那几段估，
估值随着你往下滚一直变，而进度换算两头都架在这个值上。

所以开章时先用 `TextPainter` 把每段量一遍（和渲染同一套排版引擎，量出来的就是
实际高度），把这张表交给 `itemExtentBuilder`。于是滚动范围第一帧就是准确且
恒定的，跳到任意位置也不必先把中间的段落建一遍。

代价是开章要做 O(段数) 次文本测量 —— 它不建 widget、不进 render tree、
不绘制，比建出几千个 `Text` 便宜得多，而且这是 `itemExtentBuilder` 能说真话的
唯一前提。有一个硬约束跟着来：**测量与渲染的参数必须完全一致**，
所以正文样式是 `inherit: false` 的（不继承 `DefaultTextStyle`，测量侧就不必去
猜主题会合并进来什么）。不一致的表现是每段最后一行被裁掉，
`test/reader_layout_test.dart` 拿「盒子高度 ≥ 文字自然高度」钉住了它。

### 多设备进度：只问不跳

进度是一人一本书**一条**记录、后写覆盖先写。顺序使用没问题，但一个开着没关的
页面回头滚一下，就会用它停着的旧位置盖掉另一台设备刚读到的新位置。

回到前台（`AppLifecycleState.resumed`）时拉一次服务端进度，不一致就弹窗让用户
选「跳过去 / 留在这里」。**不自动跳**：自动跳转会在「我就是想回头重读前面几章」
时把人强行拽走，而那种情况下服务端进度同样比本地靠后，程序分不出来，
只有人能分。和 funread-web 的 `checkRemoteProgress` 是同一个约定。

问到冲突之后、用户回答之前**停写**。不停的话，resumed 那一下的滚动事件会抢在
用户点下去之前把远端盖掉，问了等于没问。

### 排版设置只存本地

字号 / 行距 / 页边距 / 主题存在 `shared_preferences` 里，**不同步到服务端**。
手机和桌面的合适字号本来就不一样（一个是 390 逻辑像素宽、一手之距，一个是
1600 像素宽、一臂之距），同步过去的结果是两边互相打架。进度要同步，排版不要。

两个相关的取舍：段距跟着字号走而不单独给滑块（18px 的字配 16px 段距好看，
28px 的字配同样的段距就挤成一团）；一行最多排 36 个字，多出来的宽度摊成两侧
留白 —— 桌面上窗口多宽正文就排多宽是没法读的，所以页边距是**下限**不是定值。

### 翻页手势：边缘点击只在触屏上

点屏幕左右各 25% 翻章，但**只在 Android / iOS 上启用**。桌面上那是一条几百像素
宽的死区（2560 的屏一侧就是 640），而且鼠标用户会把点击理解成选词 ——
想复制一句话结果跳了一章。桌面给方向键（← →）和底部常驻的翻章按钮。
这个坑 funread-web 踩过，不要再踩一遍。

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

### 排版设置和系统字体缩放是两个旋钮

测量和渲染都带上了 `MediaQuery.textScalerOf`（系统字体缩放必须生效，这是
无障碍的底线），但它和应用内的字号设置是乘起来的。把系统缩放开到 200% 再把
字号拉到 30，一行排不下几个字 —— 界面上没有任何提示说明这件事。

### 进度冲突只比章节，而且只在回到前台时问一次

同一章里差几段不算冲突（否则每次切回前台都要弹一次）。两台设备**同时**在读
同一本书时，仍然是后写覆盖先写 —— 这一版解决的是「停在旧位置的页面覆盖掉新
进度」，不是实时双向同步。真要做得等后端给进度一个版本号或者更新时间。

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

这一版做完的：详情 / 目录 / 正文 / 翻章 / 进度 / 加入移出书架 /
长章节懒构建 / 排版设置 / 多设备进度冲突。
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
- **分页排版（模拟翻书）。** 这一条是**决定不做**，不是还没做：分页要先把
  渲染后的文本高度测出来再回切，字号一调就得全部重排；而滚动在触屏上是原生
  手感，在桌面上还能用滚轮和键盘。funread-web 也是同一个选择。
  （顺带：分页正文不用客户端拼，后端已经把分页抓取的多段合并好了。）
- **目录搜索 / 倒序。** 几千章的书里靠滚动找章节是能用但难用。
  目录抽屉现在只会打开时落在当前章附近。
- **超长章节的首帧。** 开章要把全章段落量一遍。常见章节（几百段）在毫秒级，
  但上万段的合集章仍会有可见停顿。真要治得分块测量或者挪进 isolate ——
  在有人真的被卡到之前不值得做，它会把「测量结果立刻可用」这个简化掉。
- **亮度 / 沉浸模式。** 原生端能真的调屏幕亮度（web 端只能压暗），
  还可以点正文中部收起工具栏。两件都要先想清楚怎么让人找得回来。
- 等后端的设备 token 落地，顺手把认证层换掉（见上）。
