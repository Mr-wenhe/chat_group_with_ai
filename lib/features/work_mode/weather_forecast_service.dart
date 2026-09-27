import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'package:chat_group/features/web_search/security/search_endpoint_dns_guard.dart';
import 'package:chat_group/features/web_search/security/search_endpoint_validator.dart';

typedef WeatherEndpointPreparer = Future<void> Function(
  Dio client,
  Uri endpoint,
);

class WeatherForecastException implements Exception {
  final String message;
  final bool retryable;

  const WeatherForecastException(this.message, {this.retryable = true});

  @override
  String toString() => 'WeatherForecastException: $message';
}

class WeatherForecastDay {
  final String date;
  final String condition;
  final int weatherCode;
  final double highCelsius;
  final double lowCelsius;
  final int precipitationProbability;
  final double maxWindSpeedKmh;

  const WeatherForecastDay({
    required this.date,
    required this.condition,
    required this.weatherCode,
    required this.highCelsius,
    required this.lowCelsius,
    required this.precipitationProbability,
    required this.maxWindSpeedKmh,
  });

  Map<String, dynamic> toMap() => {
        'date': date,
        'condition': condition,
        'weatherCode': weatherCode,
        'highCelsius': highCelsius,
        'lowCelsius': lowCelsius,
        'precipitationProbability': precipitationProbability,
        'maxWindSpeedKmh': maxWindSpeedKmh,
      };
}

class WeatherForecast {
  final String location;
  final String timezone;
  final List<WeatherForecastDay> days;

  const WeatherForecast({
    required this.location,
    required this.timezone,
    required this.days,
  });

  Map<String, dynamic> toMap() => {
        'location': location,
        'timezone': timezone,
        'days': days.map((day) => day.toMap()).toList(growable: false),
      };

  String get recommendedFileName => '未来${days.length}天天气.md';

  String toMarkdown({DateTime? generatedAt}) {
    final generated = generatedAt ?? DateTime.now();
    final timestamp = _formatTimestamp(generated);
    final rows = days.map((day) {
      return '| ${day.date} | ${day.condition} | '
          '${_formatTemperature(day.highCelsius)} | '
          '${_formatTemperature(day.lowCelsius)} | '
          '${day.precipitationProbability}% | '
          '${day.maxWindSpeedKmh.toStringAsFixed(1)} km/h |';
    }).join('\n');
    return '# $location未来${days.length}天天气预报\n\n'
        '> 生成时间：$timestamp\n'
        '> 时区：$timezone\n'
        '> 数据来源：[Open-Meteo](https://open-meteo.com/)\n\n'
        '| 日期 | 天气 | 最高温 | 最低温 | 降水概率 | 最大风速 |\n'
        '| --- | --- | ---: | ---: | ---: | ---: |\n'
        '$rows\n';
  }

  static String _formatTemperature(double value) =>
      '${value.toStringAsFixed(1)} °C';

  static String _formatTimestamp(DateTime value) {
    final local = value.toLocal();
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
        '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }
}

class WeatherForecastService {
  static const geocodingEndpoint =
      'https://geocoding-api.open-meteo.com/v1/search';
  static const forecastEndpoint = 'https://api.open-meteo.com/v1/forecast';
  static const defaultLocation = '上海';
  static const maxDays = 7;
  static const _maxLocationCharacters = 80;

  final Dio _geocodingDio;
  final Dio _forecastDio;
  final bool _isRelease;
  final String _defaultLocation;
  final WeatherEndpointPreparer _prepareEndpoint;

  WeatherForecastService({
    Dio? dio,
    String defaultLocation = WeatherForecastService.defaultLocation,
    bool? isRelease,
    WeatherEndpointPreparer? prepareEndpoint,
  })  : _geocodingDio = dio ?? _createDio(),
        _forecastDio = dio ?? _createDio(),
        _isRelease = isRelease ?? kReleaseMode,
        _defaultLocation = _normalizeLocation(defaultLocation),
        _prepareEndpoint = prepareEndpoint ??
            ((client, endpoint) => prepareSearchEndpointConnection(
                  client,
                  endpoint,
                  isRelease: isRelease ?? kReleaseMode,
                )) {
    if (_defaultLocation.isEmpty) {
      throw ArgumentError.value(defaultLocation, 'defaultLocation');
    }
  }

  Future<WeatherForecast> fetch({
    String? location,
    int days = maxDays,
    CancelToken? cancelToken,
  }) async {
    if (days < 1 || days > maxDays) {
      throw ArgumentError.value(days, 'days', '必须在 1 到 $maxDays 之间');
    }
    final requestedLocation = _normalizeLocation(location ?? '');
    final effectiveLocation =
        requestedLocation.isEmpty ? _defaultLocation : requestedLocation;
    if (effectiveLocation.isEmpty) {
      throw const WeatherForecastException(
        '未找到有效的查询地点。',
        retryable: false,
      );
    }

    final place = await _geocode(
      effectiveLocation,
      cancelToken: cancelToken,
    );
    final data = await _getJson(
      _forecastDio,
      Uri.parse(forecastEndpoint),
      query: {
        'latitude': place.latitude.toString(),
        'longitude': place.longitude.toString(),
        'daily':
            'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max',
        'forecast_days': days.toString(),
        'timezone': 'auto',
        'temperature_unit': 'celsius',
        'wind_speed_unit': 'kmh',
      },
      cancelToken: cancelToken,
    );
    return _parseForecast(
      data,
      location: place.name.isEmpty ? effectiveLocation : place.name,
      days: days,
    );
  }

  Future<_WeatherPlace> _geocode(
    String location, {
    required CancelToken? cancelToken,
  }) async {
    final data = await _getJson(
      _geocodingDio,
      Uri.parse(geocodingEndpoint),
      query: {
        'name': location,
        'count': '1',
        'language': 'zh',
        'format': 'json',
      },
      cancelToken: cancelToken,
    );
    final rawResults = data['results'];
    if (rawResults is! List || rawResults.isEmpty || rawResults.first is! Map) {
      throw const WeatherForecastException(
        '没有找到对应的天气地点。',
        retryable: false,
      );
    }
    final result = _stringKeyedMap(rawResults.first);
    if (result == null) {
      throw const WeatherForecastException(
        '天气服务返回的数据格式无效。',
        retryable: false,
      );
    }
    final latitude = _finiteNumber(result['latitude']);
    final longitude = _finiteNumber(result['longitude']);
    if (latitude == null ||
        longitude == null ||
        latitude.abs() > 90 ||
        longitude.abs() > 180) {
      throw const WeatherForecastException('天气地点坐标无效。', retryable: false);
    }
    return _WeatherPlace(
      name: _normalizeLocation(result['name']?.toString() ?? location),
      latitude: latitude,
      longitude: longitude,
    );
  }

  Future<Map<String, dynamic>> _getJson(
    Dio client,
    Uri endpoint, {
    required Map<String, String> query,
    required CancelToken? cancelToken,
  }) async {
    try {
      final validated = SearchEndpointValidator.requireValid(
        endpoint.toString(),
        isRelease: _isRelease,
      );
      await _prepareEndpoint(client, validated);
      final response = await client.get<dynamic>(
        validated.toString(),
        queryParameters: query,
        options: Options(
          responseType: ResponseType.json,
          followRedirects: false,
          maxRedirects: 0,
        ),
        cancelToken: cancelToken,
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        throw const WeatherForecastException('天气服务暂时不可用。');
      }
      final raw = response.data;
      final rawMap = _stringKeyedMap(raw);
      if (rawMap != null) return rawMap;
      if (raw is String && raw.length <= 512 * 1024) {
        final decoded = jsonDecode(raw);
        final decodedMap = _stringKeyedMap(decoded);
        if (decodedMap != null) return decodedMap;
      }
      throw const WeatherForecastException(
        '天气服务返回的数据格式无效。',
        retryable: false,
      );
    } on WeatherForecastException {
      rethrow;
    } on DioException {
      throw const WeatherForecastException('天气服务暂时不可用。');
    } on FormatException {
      throw const WeatherForecastException('天气服务返回的数据格式无效。', retryable: false);
    } on Object {
      throw const WeatherForecastException('天气服务暂时不可用。');
    }
  }

  WeatherForecast _parseForecast(
    Map<String, dynamic> data, {
    required String location,
    required int days,
  }) {
    final daily = data['daily'];
    if (daily is! Map) {
      throw const WeatherForecastException(
        '天气服务返回的数据不完整。',
        retryable: false,
      );
    }
    final values = _stringKeyedMap(daily);
    if (values == null) {
      throw const WeatherForecastException(
        '天气服务返回的数据不完整。',
        retryable: false,
      );
    }
    final dates = _stringList(values['time']);
    final codes = _numberList(values['weather_code']);
    final highs = _numberList(values['temperature_2m_max']);
    final lows = _numberList(values['temperature_2m_min']);
    final precipitation = _numberList(values['precipitation_probability_max']);
    final winds = _numberList(values['wind_speed_10m_max']);
    if (dates == null ||
        codes == null ||
        highs == null ||
        lows == null ||
        precipitation == null ||
        winds == null ||
        dates.length < days ||
        codes.length < days ||
        highs.length < days ||
        lows.length < days ||
        precipitation.length < days ||
        winds.length < days) {
      throw const WeatherForecastException(
        '天气服务返回的数据不完整。',
        retryable: false,
      );
    }
    final forecastDays = <WeatherForecastDay>[];
    for (var index = 0; index < days; index++) {
      final code = codes[index].round();
      forecastDays.add(
        WeatherForecastDay(
          date: dates[index],
          condition: _conditionFor(code),
          weatherCode: code,
          highCelsius: highs[index],
          lowCelsius: lows[index],
          precipitationProbability: _boundedPercent(
            precipitation[index],
          ),
          maxWindSpeedKmh: winds[index],
        ),
      );
    }
    final timezone = data['timezone']?.toString().trim();
    return WeatherForecast(
      location: location,
      timezone: timezone == null || timezone.isEmpty ? '当地时区' : timezone,
      days: List.unmodifiable(forecastDays),
    );
  }

  static Dio _createDio() => Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 15),
          followRedirects: false,
          maxRedirects: 0,
        ),
      );

  static String _normalizeLocation(String value) {
    final normalized = value
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.length > _maxLocationCharacters) {
      return normalized.substring(0, _maxLocationCharacters).trimRight();
    }
    return normalized;
  }

  static double? _finiteNumber(Object? value) {
    if (value is! num || !value.isFinite) return null;
    return value.toDouble();
  }

  static Map<String, dynamic>? _stringKeyedMap(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      return null;
    }
    return Map<String, dynamic>.from(value);
  }

  static List<String>? _stringList(Object? value) {
    if (value is! List || value.length > 31) return null;
    final result = value.whereType<String>().toList(growable: false);
    return result.length == value.length ? result : null;
  }

  static List<double>? _numberList(Object? value) {
    if (value is! List || value.length > 31) return null;
    final result = <double>[];
    for (final item in value) {
      final number = _finiteNumber(item);
      if (number == null) return null;
      result.add(number);
    }
    return List.unmodifiable(result);
  }

  static int _boundedPercent(double value) => value.round().clamp(0, 100);

  static String _conditionFor(int code) => switch (code) {
        0 => '晴朗',
        1 => '晴间多云',
        2 => '局部多云',
        3 => '阴天',
        45 || 48 => '雾',
        51 || 53 || 55 => '毛毛雨',
        56 || 57 => '冻毛毛雨',
        61 || 63 || 65 => '降雨',
        66 || 67 => '冻雨',
        71 || 73 || 75 || 77 => '降雪',
        80 || 81 || 82 => '阵雨',
        85 || 86 => '阵雪',
        95 || 96 || 99 => '雷雨',
        _ => '天气状况未知',
      };
}

class _WeatherPlace {
  final String name;
  final double latitude;
  final double longitude;

  const _WeatherPlace({
    required this.name,
    required this.latitude,
    required this.longitude,
  });
}
