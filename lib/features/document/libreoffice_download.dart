import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:chat_group/features/web_search/security/search_endpoint_validator.dart';

import 'libreoffice_package.dart';

/// Downloads only official package paths, following HTTPS public mirrors without credentials.
class LibreOfficeDownload {
  static const maxBytes = 1024 * 1024 * 1024;
  static const maxRedirects = 5;
  static const networkTimeout = Duration(seconds: 30);
  static const overallTimeout = Duration(minutes: 30);

  Future<String> checksum(
      LibreOfficePackage package, CancelToken cancel) async {
    final uri = package.uri.replace(path: '${package.uri.path}.sha256');
    final (client, response) = await _open(uri, cancel, officialOnly: true);
    try {
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(networkTimeout)) {
        bytes.addAll(chunk);
        if (bytes.length > 2048) {
          throw const LibreOfficeInstallException('官方校验信息超过大小上限。');
        }
      }
      return package.parseChecksum(utf8.decode(bytes));
    } finally {
      client.close(force: true);
    }
  }

  Future<void> download(
      LibreOfficePackage package,
      File target,
      CancelToken cancel,
      void Function(int received, int total) progress) async {
    final (client, response) = await _open(package.uri, cancel);
    RandomAccessFile? output;
    try {
      output = await target.open(mode: FileMode.write);
      final total = int.tryParse(
              response.headers[Headers.contentLengthHeader]?.firstOrNull ??
                  '') ??
          0;
      if (total > maxBytes) {
        throw const LibreOfficeInstallException('安装包超过下载大小上限。');
      }
      var received = 0;
      var lastPercent = -1;
      await for (final chunk in response.stream.timeout(networkTimeout)) {
        if (cancel.isCancelled) throw cancel.cancelError!;
        received += chunk.length;
        if (received > maxBytes) {
          throw const LibreOfficeInstallException('安装包超过下载大小上限。');
        }
        await output.writeFrom(chunk);
        final percent =
            total > 0 ? received * 100 ~/ total : received ~/ (1024 * 1024);
        if (percent != lastPercent) {
          lastPercent = percent;
          progress(received, total);
        }
      }
      await output.flush();
      if (received == 0 || total > 0 && received != total) {
        throw const LibreOfficeInstallException('安装包未下载完整，请重试。');
      }
    } finally {
      try {
        await output?.close();
      } finally {
        client.close(force: true);
      }
    }
  }

  Future<(Dio, ResponseBody)> _open(Uri original, CancelToken cancel,
      {bool officialOnly = false}) async {
    var uri = original;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      if (cancel.isCancelled) throw cancel.cancelError!;
      if (!SearchEndpointValidator.validate(uri.toString(), isRelease: true)
              .isValid ||
          uri.scheme != 'https' ||
          officialOnly && uri.host != LibreOfficePackage.host) {
        throw const LibreOfficeInstallException('下载地址不安全，已停止下载。');
      }
      final client = Dio(BaseOptions(
          connectTimeout: networkTimeout,
          receiveTimeout: networkTimeout,
          followRedirects: false,
          responseType: ResponseType.stream,
          validateStatus: (_) => true));
      try {
        // Normal HTTPS resolution also supports user VPN/proxy fake-IP DNS.
        // Official checksum metadata and system signatures authenticate installer bytes.
        final response =
            await client.getUri<ResponseBody>(uri, cancelToken: cancel);
        if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers.value('location');
          client.close(force: true);
          if (location == null) break;
          uri = uri.resolve(location);
          continue;
        }
        if (response.statusCode != 200 || response.data == null) {
          throw const LibreOfficeInstallException('官方安装包暂时无法下载，请稍后重试。');
        }
        return (client, response.data!);
      } on Object {
        client.close(force: true);
        rethrow;
      }
    }
    throw const LibreOfficeInstallException('安装包下载重定向过多，请稍后重试。');
  }
}
