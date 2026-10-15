import 'package:dio/dio.dart';

/// 既不是 dart:io 也不是浏览器的编译目标。真机上走不到，
/// 存在的意义是让条件导入有个默认分支、让 `flutter analyze` 有东西可解析。
Future<void> attachCookieStore(Dio dio) async {}

Future<void> clearCookieStore() async {}
