import 'package:flutter/foundation.dart';
import 'package:chat_group/core/models/api_provider.dart';
import '../data/search_settings_store.dart';
import '../models/search_models.dart';
import '../providers/native_web_search_adapter.dart';
import 'search_provider_route.dart';

/// Legacy search scenes retain only Zhipu; autonomous networking has its own tools.
///
/// 路由生成只取决于"有没有可用的智谱原生绑定"，与调用侧是不是"仅原生"模式无关。
/// 那个开关过去以一个从未被读取的参数传进来：它真正的作用点在调用侧（要不要
/// 先花一次模型请求做查询改写），留在这里只会让人以为工厂会为两种模式生成不同
/// 路由。
class SearchRuntimeProviderFactory {
  final SearchProviderConfigStore store;
  SearchRuntimeProviderFactory({required this.store});

  List<SearchProviderRoute> buildRoutes({NativeWebSearchBinding? nativeSearch}) {
    if (kIsWeb ||
        nativeSearch == null ||
        nativeSearch.provider != ApiProvider.zhipu) {
      return const [];
    }
    final adapter = NativeWebSearchAdapterRegistry(isRelease: store.isRelease)
        .resolve(provider: nativeSearch.provider, model: nativeSearch.model);
    if (adapter == null) return const [];
    return [
      SearchProviderRoute(
        id: 'native:${nativeSearch.provider.name}:${nativeSearch.model}',
        provider:
            NativeWebSearchProvider(adapter: adapter, binding: nativeSearch),
        isPrimary: true,
        isNative: true,
        priority: 0,
        displayName:
            '${nativeSearch.provider.label} ${nativeSearch.model}（原生联网）',
      )
    ];
  }

  static bool isProviderAllowedForPlatform(SearchProviderKind provider,
          {required bool isWeb, required bool isRelease}) =>
      !isWeb && provider == SearchProviderKind.nativeModel;
}
