import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/mitm/mitm_script.dart';
import 'package:fl_clash/mitm/mitm_script_server.dart';
import 'package:fl_clash/mitm/mitm_settings.dart';
import 'package:fl_clash/mitm/mitm_storage.dart';

class MitmManager {
  Future<MitmSettings> loadSettings() async {
    final map = await preferences.getMitmSettingsMap();
    return MitmSettings.fromJson(map);
  }

  Future<void> saveSettings(MitmSettings settings) async {
    await preferences.saveMitmSettingsMap(settings.toJson());
  }

  Future<File> _file(String name) => mitmFile(name);

  Future<String?> readCaCertPem() async {
    final f = await _file('ca_cert.pem');
    if (!await f.exists()) return null;
    return await f.readAsString();
  }

  Future<String?> readCaKeyPem() async {
    final f = await _file('ca_key.pem');
    if (!await f.exists()) return null;
    return await f.readAsString();
  }

  Future<void> writeCaCertPem(String pem) async {
    final f = await _file('ca_cert.pem');
    await f.safeWriteAsString(pem);
  }

  Future<void> writeCaKeyPem(String pem) async {
    final f = await _file('ca_key.pem');
    await f.safeWriteAsString(pem);
  }

  Future<void> clearCaCert() async {
    await (await _file('ca_cert.pem')).safeDelete();
  }

  Future<void> clearCaKey() async {
    await (await _file('ca_key.pem')).safeDelete();
  }

  Future<File> _scriptsFile() => _file('scripts.json');

  Future<List<MitmScript>> loadScripts() async {
    final f = await _scriptsFile();
    if (!await f.exists()) return const [];
    try {
      final raw = await f.readAsString();
      final decoded = json.decode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => MitmScript.fromJson(Map<String, Object?>.from(e)))
          .where((e) => e.id.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveScripts(List<MitmScript> scripts) async {
    final f = await _scriptsFile();
    final list = scripts.map((e) => e.toJson()).toList(growable: false);
    await f.safeWriteAsString(json.encode(list));
  }

  Future<String?> applyToCore({
    MitmSettings? settings,
    String? caCertPem,
    String? caKeyPem,
  }) async {
    if (!system.isAndroid) return null;
    final s = settings ?? await loadSettings();

    final scripts = await loadScripts();
    final enabledScripts = scripts
        .where(
          (e) =>
              e.enable && e.content.trim().isNotEmpty && e.domains.isNotEmpty,
        )
        .toList(growable: false);
    final shouldEnableScriptServer = s.enable && enabledScripts.isNotEmpty;
    final wasScriptServerStarted = mitmScriptServer.isStarted;
    MitmScriptServerInfo? scriptInfo;
    if (shouldEnableScriptServer) {
      scriptInfo = await mitmScriptServer.ensureStarted();
      final compileErr = await mitmScriptServer.updateScripts(enabledScripts);
      if (compileErr != null) {
        if (!wasScriptServerStarted) {
          await mitmScriptServer.stop();
        }
        return compileErr;
      }
    } else {
      await mitmScriptServer.stop();
    }

    final scriptTimeoutBudgetMs = enabledScripts.isEmpty
        ? MitmScript.defaultTimeoutMs
        : enabledScripts
              .map((e) => e.effectiveTimeoutMs)
              .fold<int>(0, (a, b) => a + b);
    final coreScriptTimeoutMs = (scriptTimeoutBudgetMs + 400).clamp(
      400,
      10 * 1000,
    );

    final cert = caCertPem ?? (await readCaCertPem()) ?? '';
    final key = caKeyPem ?? (await readCaKeyPem()) ?? '';

    final domainSet = enabledScripts.expand((e) => e.domains).toSet();

    final config = <String, dynamic>{
      'enable': s.enable,
      'ca-cert': cert,
      'ca-key': key,
      'domains': domainSet.toList(growable: false),
      'capture-max-bytes': s.captureMaxBytes,
      'store-size': s.storeSize,
      'skip-verify': s.skipVerify,
      'script-enable': shouldEnableScriptServer && scriptInfo != null,
      'script-url': scriptInfo?.url ?? '',
      'script-token': scriptInfo?.token ?? '',
      'script-timeout-ms': coreScriptTimeoutMs,
    };

    commonPrint.log('Invoke setMitmConfig');
    var ok = false;
    for (var attempt = 0; attempt < 6; attempt++) {
      ok = await coreController.setMitmConfig(config);
      if (ok) break;
      if (attempt < 5) {
        final ms = (200 * (attempt + 1)).clamp(200, 1200);
        commonPrint.log('setMitmConfig retry ${attempt + 1} (sleep ${ms}ms)');
        await Future<void>.delayed(Duration(milliseconds: ms));
      }
    }
    if (!ok) {
      commonPrint.log('setMitmConfig failed');
      return 'setMitmConfig failed';
    }
    commonPrint.log('setMitmConfig ok');
    return null;
  }
}

final mitmManager = MitmManager();
