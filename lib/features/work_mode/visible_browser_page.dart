import 'dart:convert';

import 'visible_browser_models.dart';

const int visibleBrowserMaxEncodedPageCharacters = 64 * 1024;

class VisibleBrowserPageCapture {
  final String url;
  final String title;
  final String text;

  const VisibleBrowserPageCapture({
    required this.url,
    required this.title,
    required this.text,
  });
}

VisibleBrowserPageCapture decodeVisibleBrowserPage(
  String? encoded,
  Uri fallback,
) {
  if (encoded == null || encoded.trim().isEmpty) {
    return VisibleBrowserPageCapture(
      url: fallback.toString(),
      title: '',
      text: '',
    );
  }
  if (encoded.length > visibleBrowserMaxEncodedPageCharacters) {
    throw const FormatException('公开网页读取结果超过大小上限');
  }
  dynamic decoded = jsonDecode(encoded);
  if (decoded is String) {
    decoded = jsonDecode(decoded);
  }
  if (decoded is! Map) {
    throw const FormatException('公开网页读取结果无效');
  }
  final rawUrl = decoded['url'];
  final rawTitle = decoded['title'];
  final rawText = decoded['text'];
  return VisibleBrowserPageCapture(
    url: rawUrl is String && rawUrl.trim().isNotEmpty
        ? rawUrl
        : fallback.toString(),
    title: rawTitle is String ? rawTitle : '',
    text: rawText is String ? rawText : '',
  );
}

VisibleBrowserPauseReason? detectVisibleBrowserPauseReason(
  String title,
  String text,
) {
  final value = '$title $text'.toLowerCase();
  if (_containsAny(value, <String>[
    'captcha',
    'recaptcha',
    'hcaptcha',
    'cloudflare',
    'verify you are human',
    'unusual traffic',
    'robot check',
    '验证码',
    '人机验证',
    '验证您是人类',
  ])) {
    return VisibleBrowserPauseReason.captcha;
  }
  if (_containsAny(value, <String>[
    'login',
    'log in',
    'sign in',
    'sign-in',
    '登录',
    '登陆',
    'sign in to continue',
    '登录后继续',
    '需要登录',
    '请先登录',
  ])) {
    return VisibleBrowserPauseReason.login;
  }
  if (_containsAny(value, <String>[
    'paywall',
    'subscribe to continue',
    'subscription required',
    'subscribers only',
    'premium content',
    'purchase required',
    '付费墙',
    '订阅后',
    '订阅才能阅读',
    '付费内容',
    '购买后',
  ])) {
    return VisibleBrowserPauseReason.paywall;
  }
  return null;
}

String visibleBrowserPauseReasonLabel(VisibleBrowserPauseReason reason) =>
    switch (reason) {
      VisibleBrowserPauseReason.login => '网页要求登录',
      VisibleBrowserPauseReason.captcha => '网页要求完成验证码或人机验证',
      VisibleBrowserPauseReason.paywall => '网页遇到付费墙或订阅限制',
    };

bool _containsAny(String value, List<String> needles) =>
    needles.any(value.contains);
