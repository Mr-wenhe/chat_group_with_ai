import 'package:chat_group/features/work_mode/weather_forecast_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fetches and formats a seven-day forecast without shell commands',
      () async {
    final requestedUris = <Uri>[];
    final dio = _fixtureDio((options) {
      requestedUris.add(options.uri);
      if (options.uri.host == 'geocoding-api.open-meteo.com') {
        return {
          'results': [
            {
              'name': '上海',
              'latitude': 31.2304,
              'longitude': 121.4737,
              'timezone': 'Asia/Shanghai',
            },
          ],
        };
      }
      return {
        'daily': {
          'time': List<String>.generate(
            7,
            (index) => '2026-09-${(11 + index).toString().padLeft(2, '0')}',
          ),
          'weather_code': List<int>.filled(7, 1),
          'temperature_2m_max': List<num>.generate(7, (index) => 28 + index),
          'temperature_2m_min': List<num>.generate(7, (index) => 20 + index),
          'precipitation_probability_max': List<int>.filled(7, 30),
          'wind_speed_10m_max': List<num>.filled(7, 18),
        },
      };
    });

    final service = WeatherForecastService(
      dio: dio,
      isRelease: true,
      prepareEndpoint: (_, __) async {},
    );
    final forecast = await service.fetch(location: '上海', days: 7);

    expect(forecast.location, '上海');
    expect(forecast.days, hasLength(7));
    expect(forecast.days.first.condition, '晴间多云');
    expect(forecast.days.first.highCelsius, 28);
    expect(forecast.days.last.lowCelsius, 26);
    expect(forecast.toMarkdown(),
        contains('| 日期 | 天气 | 最高温 | 最低温 | 降水概率 | 最大风速 |'));
    expect(
      requestedUris.map((uri) => uri.host),
      ['geocoding-api.open-meteo.com', 'api.open-meteo.com'],
    );
    expect(requestedUris.every((uri) => uri.scheme == 'https'), isTrue);
  });

  test('uses a deterministic saved-location fallback when request omits city',
      () async {
    final queries = <String>[];
    final dio = _fixtureDio((options) {
      if (options.uri.host == 'geocoding-api.open-meteo.com') {
        queries.add(options.uri.queryParameters['name'] ?? '');
        return {
          'results': [
            {'name': '上海', 'latitude': 31.23, 'longitude': 121.47},
          ],
        };
      }
      return _forecastPayload();
    });

    final forecast = await WeatherForecastService(
      dio: dio,
      defaultLocation: '上海',
      prepareEndpoint: (_, __) async {},
    ).fetch();

    expect(queries, ['上海']);
    expect(forecast.location, '上海');
    expect(forecast.days, hasLength(7));
  });

  test('treats a blank location as an omitted location', () async {
    final queries = <String>[];
    final dio = _fixtureDio((options) {
      if (options.uri.host == 'geocoding-api.open-meteo.com') {
        queries.add(options.uri.queryParameters['name'] ?? '');
        return {
          'results': [
            {'name': '上海', 'latitude': 31.23, 'longitude': 121.47},
          ],
        };
      }
      return _forecastPayload();
    });

    await WeatherForecastService(
      dio: dio,
      defaultLocation: '上海',
      prepareEndpoint: (_, __) async {},
    ).fetch(location: '   ');

    expect(queries, ['上海']);
  });

  test('uses the requested day count in the Markdown heading', () async {
    final dio = _fixtureDio((options) {
      if (options.uri.host == 'geocoding-api.open-meteo.com') {
        return {
          'results': [
            {'name': '上海', 'latitude': 31.23, 'longitude': 121.47},
          ],
        };
      }
      return _forecastPayload();
    });

    final forecast = await WeatherForecastService(
      dio: dio,
      prepareEndpoint: (_, __) async {},
    ).fetch(location: '上海', days: 3);

    final markdown = forecast.toMarkdown(
      generatedAt: DateTime(2026, 9, 11, 10),
    );
    expect(markdown, startsWith('# 上海未来3天天气预报'));
    expect(markdown, isNot(startsWith('# 上海未来7天天气预报')));
    expect(forecast.recommendedFileName, '未来3天天气.md');
  });

  test('does not invent zero values when requested metrics are missing',
      () async {
    final dio = _fixtureDio((options) {
      if (options.uri.host == 'geocoding-api.open-meteo.com') {
        return {
          'results': [
            {'name': '上海', 'latitude': 31.23, 'longitude': 121.47},
          ],
        };
      }
      return {
        'daily': {
          'time': ['2026-09-11'],
          'weather_code': [0],
          'temperature_2m_max': [27],
          'temperature_2m_min': [19],
        },
      };
    });

    await expectLater(
      WeatherForecastService(
        dio: dio,
        prepareEndpoint: (_, __) async {},
      ).fetch(location: '上海', days: 1),
      throwsA(
        isA<WeatherForecastException>().having(
          (error) => error.message,
          'message',
          contains('天气服务返回的数据不完整'),
        ),
      ),
    );
  });

  test('reports malformed forecast data as a safe retryable failure', () async {
    final dio = _fixtureDio((options) {
      if (options.uri.host == 'geocoding-api.open-meteo.com') {
        return {
          'results': [
            {'name': '上海', 'latitude': 31.23, 'longitude': 121.47},
          ],
        };
      }
      return {
        'daily': {
          'time': ['2026-09-11']
        }
      };
    });

    await expectLater(
      WeatherForecastService(
        dio: dio,
        prepareEndpoint: (_, __) async {},
      ).fetch(location: '上海'),
      throwsA(
        isA<WeatherForecastException>().having(
          (error) => error.message,
          'message',
          contains('天气服务返回的数据不完整'),
        ),
      ),
    );
  });

  test('rejects forecast objects with non-string keys safely', () async {
    final dio = _fixtureDio((options) {
      if (options.uri.host == 'geocoding-api.open-meteo.com') {
        return {
          'results': [
            {'name': '上海', 'latitude': 31.23, 'longitude': 121.47},
          ],
        };
      }
      return {
        'daily': {1: 'invalid'},
      };
    });

    await expectLater(
      WeatherForecastService(
        dio: dio,
        prepareEndpoint: (_, __) async {},
      ).fetch(location: '上海', days: 1),
      throwsA(
        isA<WeatherForecastException>().having(
          (error) => error.message,
          'message',
          contains('天气服务返回的数据不完整'),
        ),
      ),
    );
  });

  test('treats malformed top-level maps as non-retryable format failures',
      () async {
    final dio = _fixtureDio((options) {
      if (options.uri.host == 'geocoding-api.open-meteo.com') {
        return {
          'results': [
            {'name': '上海', 'latitude': 31.23, 'longitude': 121.47},
          ],
        };
      }
      return <Object?, dynamic>{1: 'invalid'};
    });

    await expectLater(
      WeatherForecastService(
        dio: dio,
        prepareEndpoint: (_, __) async {},
      ).fetch(location: '上海'),
      throwsA(
        isA<WeatherForecastException>()
            .having((error) => error.message, 'message', contains('数据格式无效'))
            .having((error) => error.retryable, 'retryable', isFalse),
      ),
    );
  });
}

Map<String, dynamic> _forecastPayload() => {
      'daily': {
        'time': List<String>.generate(
          7,
          (index) => '2026-09-${(11 + index).toString().padLeft(2, '0')}',
        ),
        'weather_code': List<int>.filled(7, 0),
        'temperature_2m_max': List<num>.filled(7, 27),
        'temperature_2m_min': List<num>.filled(7, 19),
        'precipitation_probability_max': List<int>.filled(7, 0),
        'wind_speed_10m_max': List<num>.filled(7, 12),
      },
    };

Dio _fixtureDio(Object? Function(RequestOptions) response) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: response(options),
          ),
        );
      },
    ),
  );
  return dio;
}
