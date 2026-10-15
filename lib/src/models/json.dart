/// 解析后端出参用的强制转换助手。
///
/// 为什么是手写 `fromJson` 而不是 json_serializable：codegen 只有两种落法，
/// 要么把 `.g.dart` 提交进仓库（review 噪音，而且一旦有人手改就和源文件漂移），
/// 要么在 CI 里多跑一遍 build_runner（多一层版本耦合，而这个仓库的 CI 本来
/// 就是唯一的编译验证手段，不该再加不确定性）。这一版只有七个模型，
/// 手写的总成本低于引入 codegen。模型数量上到二三十个再换不迟。
///
/// 这些函数一律**不抛**。后端是会演进的，多一个字段、把 `0` 写成 `"0"`、
/// 把空值从 `""` 改成 `null`，都不该让客户端白屏 —— 对阅读器来说，
/// 少显示一个字数统计远好过整页解析失败。
library;

typedef JsonMap = Map<String, dynamic>;

String asString(Object? value) {
  if (value is String) return value;
  if (value == null) return '';
  return value.toString();
}

String? asStringOrNull(Object? value) => value == null ? null : asString(value);

int asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

int? asIntOrNull(Object? value) => value == null ? null : asInt(value);

double asDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

bool asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value == 'true' || value == '1';
  return false;
}

/// 规则引擎的 `variables`：键值都是字符串，但后端只保证是个对象。
Map<String, String> asStringMap(Object? value) {
  if (value is! Map) return const <String, String>{};
  return <String, String>{
    for (final MapEntry<Object?, Object?> entry in value.entries)
      asString(entry.key): asString(entry.value),
  };
}

/// 列表元素里混进非对象的那些直接丢掉，而不是整列表失败。
List<T> asList<T>(Object? value, T Function(JsonMap) parse) {
  if (value is! List) return <T>[];
  final List<T> items = <T>[];
  for (final Object? item in value) {
    if (item is Map) {
      items.add(parse(item.cast<String, dynamic>()));
    }
  }
  return items;
}

JsonMap asMap(Object? value) {
  if (value is Map) return value.cast<String, dynamic>();
  return <String, dynamic>{};
}
