import '../models/search_provider_config.dart';

/// Shared boundary validation for user-supplied search credentials.
class SearchCredentialValidator {
  static final _controlCharacterPattern = RegExp(r'[\u0000-\u001F\u007F]');

  const SearchCredentialValidator._();

  static String? validate(String value) {
    if (value.length > SearchProviderConfig.maxCredentialLength) {
      return '凭据过长';
    }
    if (_controlCharacterPattern.hasMatch(value)) {
      return '凭据包含非法控制字符';
    }
    return null;
  }
}
