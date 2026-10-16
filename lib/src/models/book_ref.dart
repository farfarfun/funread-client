import 'search.dart';
import 'shelf.dart';

/// 「从哪个源读哪本书」这组坐标。
///
/// 这**不是**后端的 response_model，是客户端自己的值类型。之所以要它：
/// `url_id` / `book_url` / `book_key` / `name` / `author` 这五个字段在
/// 搜索结果 → 详情 → 目录 → 正文 → 进度回写的整条链上一路同行，摊成五个
/// 参数往下传，少传一个的表现是 404 或者静默读到空，而不是编译错误。
///
/// 和 funread-web 的差别在这里：web 把这组值塞在 URL query 里（刷新要能恢复），
/// Flutter 是对象导航，直接把它当路由参数传，顺带也就不会在序列化时丢字段。
class BookRef {
  const BookRef({
    required this.bookKey,
    required this.urlId,
    required this.bookUrl,
    this.name = '',
    this.author = '',
  });

  /// 从搜索结果的某个源进来。一本书在多个源下都有，哪个源真能读出正文，
  /// 要到目录 / 正文那步才知道，所以源是用户在详情面板里选的。
  factory BookRef.fromSearch(SearchBook book, SourceRef source) {
    return BookRef(
      bookKey: book.bookKey,
      urlId: source.urlId,
      bookUrl: source.bookUrl,
      name: book.name,
      author: book.author,
    );
  }

  /// 从书架进来。`url_id` 可以是 null（手动加的书还没定源），
  /// 这里退化成 0，由 [isUsable] 拦住。
  factory BookRef.fromShelf(ShelfBook book) {
    return BookRef(
      bookKey: book.bookKey,
      urlId: book.urlId ?? 0,
      bookUrl: book.bookUrl,
      name: book.name,
      author: book.author,
    );
  }

  /// `md5(书名\n作者)`。书架、服务端章节缓存、换源都用它当主键。
  ///
  /// **永远用后端给的那个**（搜索结果 / 加入书架的出参），不要在客户端算 ——
  /// 书名里的空白和异体字怎么归一化是后端的事。
  final String bookKey;

  final int urlId;
  final String bookUrl;

  /// 书名 / 作者只是给源做二次校验用的（`GET /reader/book` 的可选入参），
  /// 不参与定位。
  final String name;
  final String author;

  /// 够不够打 `/reader/book`。不够的话界面要说「缺少来源信息」，
  /// 而不是发一个注定 422 的请求。
  bool get isUsable => urlId > 0 && bookUrl.isNotEmpty;

  /// 加入书架之后用后端返回的 key 覆盖。两者通常相同，但书名/作者的归一化
  /// 口径以后端为准 —— 用错 key 的表现是「进度存进了另一本书」。
  BookRef withBookKey(String value) {
    return BookRef(
      bookKey: value,
      urlId: urlId,
      bookUrl: bookUrl,
      name: name,
      author: author,
    );
  }
}
