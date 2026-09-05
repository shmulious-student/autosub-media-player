import 'package:autosub_media_player/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('BackendEnvironment defaults to local', () {
    final settings = AppSettings();
    expect(settings.backendEnvironment, BackendEnvironment.local);
    expect(settings.hasAnyCloudKey, isFalse);
  });

  test('BackendEnvironment switches to cloud and reflects keys', () {
    final settings = AppSettings(
      backendEnvironment: BackendEnvironment.cloud,
      groqApiKey: 'gsk_123',
      geminiApiKey: 'AIzaSy456',
    );

    expect(settings.backendEnvironment, BackendEnvironment.cloud);
    expect(settings.hasGroqKey, isTrue);
    expect(settings.hasGeminiKey, isTrue);
    expect(settings.hasCloudflareCredentials, isFalse);
    expect(settings.hasAnyCloudKey, isTrue);
  });

  test('Cloudflare credentials require both account id and token', () {
    final settings = AppSettings(cloudflareAccountId: 'acc123');
    expect(settings.hasCloudflareCredentials, isFalse);

    settings.cloudflareApiToken = 'tok456';
    expect(settings.hasCloudflareCredentials, isTrue);
  });

  test('BackendEnvironment labels and wire values match', () {
    expect(BackendEnvironment.local.wire, 'local');
    expect(BackendEnvironment.cloud.wire, 'cloud');
    expect(BackendEnvironment.local.shortLabel, 'Local');
    expect(BackendEnvironment.cloud.shortLabel, 'Cloud');
  });
}
