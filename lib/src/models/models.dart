/// 模型层的统一入口。界面和 API 层都只 import 这一个文件，
/// 这样以后拆分 / 合并模型文件不用去改调用方。
library;

export 'book.dart';
export 'book_ref.dart';
// 只放出 API 层真正要用的两个解析助手（把出参 cast 成对象 / 列表）。
// asString / asInt 这些是模型自己的事，不该出现在调用方。
export 'json.dart' show JsonMap, asList, asMap;
export 'paragraph.dart';
export 'reader_settings.dart';
export 'search.dart';
export 'session_state.dart';
export 'shelf.dart';
export 'switch_source.dart';
