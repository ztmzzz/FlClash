import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/mitm/mitm_kv_store.dart';
import 'package:fl_clash/mitm/mitm_script.dart';
import 'package:flutter_js/flutter_js.dart';

class MitmScriptServerInfo {
  final String url;
  final String token;
  final int port;

  const MitmScriptServerInfo({
    required this.url,
    required this.token,
    required this.port,
  });
}

class MitmScriptServer {
  HttpServer? _server;
  String? _token;
  int? _port;

  JavascriptRuntime? _runtime;

  List<MitmScript> _scripts = const [];

  Future<void> _seq = Future.value();

  Map<String, dynamic> _kvSnapshot = const {};

  bool get isStarted => _server != null;

  MitmScriptServerInfo? get info {
    final port = _port;
    final token = _token;
    if (port == null || token == null) return null;
    return MitmScriptServerInfo(
      url: 'http://$localhost:$port/mitm',
      token: token,
      port: port,
    );
  }

  Future<MitmScriptServerInfo?> ensureStarted() async {
    if (!system.isAndroid) return null;
    if (_server != null) return info;

    _token = utils.id;
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    _server = server;
    _port = server.port;

    server.listen((req) async {
      try {
        await _handle(req);
      } catch (e) {
        try {
          req.response.statusCode = HttpStatus.internalServerError;
          req.response.headers.contentType = ContentType.json;
          req.response.write(json.encode({'error': e.toString()}));
          await req.response.close();
        } catch (_) {}
      }
    });

    return info;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _port = null;
    _token = null;
    _scripts = const [];
    _kvSnapshot = const {};
    final runtime = _runtime;
    _runtime = null;
    if (s != null) {
      await s.close(force: true);
    }
    if (runtime != null) {
      try {
        runtime.dispose();
      } catch (_) {}
    }
  }

  Future<void> _refreshKvSnapshot() async {
    try {
      _kvSnapshot = await mitmKvStore.snapshot();
    } catch (_) {
      _kvSnapshot = const {};
    }
  }

  Future<String?> updateScripts(List<MitmScript> enabledScripts) async {
    final nextScripts = List<MitmScript>.from(enabledScripts, growable: false);
    if (nextScripts.isEmpty) {
      _scripts = const [];
      return null;
    }
    return await _serialize(() async {
      _runtime ??= getJavascriptRuntime();
      for (final s in nextScripts) {
        final err = await _validateScript(s);
        if (err != null) {
          return 'Script "${s.name}": $err';
        }
      }
      _scripts = nextScripts;
      return null;
    });
  }

  Future<T> _serialize<T>(Future<T> Function() fn) {
    final completer = Completer<T>();
    _seq = _seq.then((_) async {
      try {
        completer.complete(await fn());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> _handle(HttpRequest req) async {
    if (req.method != 'POST' || req.uri.path != '/mitm') {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }

    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    if (_token == null || auth != 'Bearer $_token') {
      req.response.statusCode = HttpStatus.unauthorized;
      await req.response.close();
      return;
    }

    final content = await utf8.decoder.bind(req).join();
    Map<String, dynamic> payload;
    try {
      final decoded = json.decode(content);
      if (decoded is! Map) {
        throw const FormatException('payload must be an object');
      }
      payload = Map<String, dynamic>.from(decoded);
    } catch (e) {
      req.response.statusCode = HttpStatus.badRequest;
      req.response.headers.contentType = ContentType.json;
      req.response.write(json.encode({'error': e.toString()}));
      await req.response.close();
      return;
    }

    final res = await _serialize(() async {
      if (_scripts.isEmpty) return <String, dynamic>{};
      _runtime ??= getJavascriptRuntime();

      await _refreshKvSnapshot();

      final host = (payload['host'] as String?) ?? '';
      final phase = (payload['phase'] as String?) ?? '';
      if (host.isEmpty || phase.isEmpty) return <String, dynamic>{};

      final matched = _scripts
          .where((s) => _matchAnyDomain(host, s.domains))
          .toList();
      if (matched.isEmpty) return <String, dynamic>{};

      final out = <String, dynamic>{};
      final errors = <String>[];

      for (final s in matched) {
        final ctxJson = json.encode(_augmentPayload(payload));
        final result = await _runScriptOnce(s, ctxJson);
        final err = result['__error'] as String?;
        if (err != null && err.isNotEmpty) {
          errors.add('${s.name}: $err');
        }
        final mod = result['__mod'];
        if (mod is Map) {
          final modMap = Map<String, dynamic>.from(mod);
          _normalizeBodyFields(modMap);

          final kv = modMap.remove('kv');
          if (kv is Map) {
            final kvMap = Map<String, dynamic>.from(kv);
            final setRaw = kvMap['set'];
            final removeRaw = kvMap['remove'];
            final set = setRaw is Map
                ? Map<String, dynamic>.from(setRaw)
                : null;
            final remove = removeRaw is List
                ? removeRaw.whereType<String>().toList(growable: false)
                : null;
            final kvErr = await mitmKvStore.applyMutations(
              set: set,
              remove: remove,
            );
            if (kvErr != null) {
              errors.add('${s.name}: kv: $kvErr');
            } else {
              // Keep snapshot in sync for subsequent scripts in the same request.
              await _refreshKvSnapshot();
            }
          }

          final reply = modMap['reply'];
          if (phase == 'request' && reply is Map) {
            return {
              'reply': reply,
              if (errors.isNotEmpty) 'error': errors.join(' | '),
            };
          }
          _mergeMods(out, modMap);
        }
      }

      if (errors.isNotEmpty) {
        out['error'] = errors.join(' | ');
      }
      return out;
    });

    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentType = ContentType.json;
    req.response.write(json.encode(res));
    await req.response.close();
  }

  Future<String?> _validateScript(MitmScript s) async {
    if (!s.enable) return null;
    if (s.domains.isEmpty) return 'domains is empty';
    if (s.content.trim().isEmpty) return 'content is empty';
    final runtime = _runtime ??= getJavascriptRuntime();
    final js =
        '''
      (function() {
        try {
          ${s.content}
          return (typeof handle === "function") ? "" : "script must define function handle(ctx)";
        } catch (e) {
          return String(e && e.stack ? e.stack : e);
        }
      })()
    ''';
    final timeout = Duration(milliseconds: s.effectiveTimeoutMs);
    try {
      final res = await runtime.evaluateAsync(js).timeout(timeout);
      if (res.isError) return res.stringResult;
      final msg = res.stringResult;
      if (msg.isNotEmpty) return msg;
      return null;
    } on TimeoutException {
      return 'validate timeout (${s.effectiveTimeoutMs}ms)';
    } catch (e) {
      return 'validate error: $e';
    }
  }

  Future<Map<String, dynamic>> _runScriptOnce(
    MitmScript s,
    String ctxJson,
  ) async {
    final runtime = _runtime ??= getJavascriptRuntime();
    final timeout = Duration(milliseconds: s.effectiveTimeoutMs);
    final js =
        '''
      (function() {
        try {
          ${s.content}
          if (typeof handle !== "function") { return JSON.stringify({"__error":"script must define function handle(ctx)"}); }
          var __r = handle($ctxJson);
          if (__r === undefined) { return ""; }
          return JSON.stringify({"__mod": __r});
        } catch (e) {
          return JSON.stringify({"__error": String(e && e.stack ? e.stack : e)});
        }
      })()
    ''';
    try {
      final evalRes = await runtime.evaluateAsync(js).timeout(timeout);
      if (evalRes.isError) {
        return {'__error': evalRes.stringResult};
      }
      final raw = evalRes.stringResult;
      if (raw.isEmpty) return const {};
      try {
        final decoded = json.decode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
      return const {};
    } on TimeoutException {
      return {'__error': 'runtime timeout (${s.effectiveTimeoutMs}ms)'};
    } catch (e) {
      return {'__error': 'runtime error: $e'};
    }
  }

  bool _matchAnyDomain(String host, List<String> domains) {
    final h = _normalizeHost(host);
    if (h.isEmpty) return false;
    for (final d in domains) {
      if (_matchDomain(h, d)) return true;
    }
    return false;
  }

  String _normalizeHost(String host) {
    var h = host.trim().toLowerCase();
    while (h.endsWith('.')) {
      h = h.substring(0, h.length - 1);
    }
    return h;
  }

  bool _matchDomain(String host, String pattern) {
    var p = pattern.trim().toLowerCase();
    while (p.endsWith('.')) {
      p = p.substring(0, p.length - 1);
    }
    if (p.isEmpty) return false;
    if (p.startsWith('*.')) {
      final base = p.substring(2);
      if (base.isEmpty) return false;
      return host != base && host.endsWith('.$base');
    }
    return host == p || host.endsWith('.$p');
  }

  void _mergeMods(Map<String, dynamic> base, Map<String, dynamic> add) {
    void mergeSection(String key) {
      final a = add[key];
      if (a is! Map) return;
      final b = base[key];
      final merged = <String, dynamic>{};
      if (b is Map) merged.addAll(Map<String, dynamic>.from(b));
      final aMap = Map<String, dynamic>.from(a);

      void mergeMapField(String name) {
        final bm = merged[name];
        final am = aMap[name];
        final out = <String, dynamic>{};
        if (bm is Map) out.addAll(Map<String, dynamic>.from(bm));
        if (am is Map) out.addAll(Map<String, dynamic>.from(am));
        if (out.isNotEmpty) merged[name] = out;
      }

      void mergeListField(String name) {
        final bm = merged[name];
        final am = aMap[name];
        final set = <String>{};
        if (bm is List) set.addAll(bm.whereType<String>());
        if (am is List) set.addAll(am.whereType<String>());
        if (set.isNotEmpty) merged[name] = set.toList(growable: false);
      }

      for (final scalar in const [
        'method',
        'path',
        'status',
        'bodyBase64',
        'bodyText',
        'body',
      ]) {
        if (aMap.containsKey(scalar)) {
          merged[scalar] = aMap[scalar];
        }
      }
      mergeMapField('setHeaders');
      mergeListField('removeHeaders');

      base[key] = merged;
    }

    mergeSection('request');
    mergeSection('response');
  }

  Map<String, dynamic> _augmentPayload(Map<String, dynamic> inMap) {
    final c = json.decode(json.encode(inMap)) as Map<String, dynamic>;
    _injectBodyText(c['request']);
    _injectBodyText(c['response']);
    c['kv'] = _kvSnapshot;
    return c;
  }

  void _injectBodyText(dynamic section) {
    if (section is! Map) return;
    final bodyBase64 = section['bodyBase64'];
    if (bodyBase64 is! String || bodyBase64.isEmpty) return;
    try {
      final bytes = base64.decode(bodyBase64);
      final text = utf8.decode(bytes, allowMalformed: true);
      section['bodyText'] = text;
    } catch (_) {}
  }

  void _normalizeBodyFields(Map<String, dynamic> out) {
    for (final k in const ['request', 'response', 'reply']) {
      final section = out[k];
      if (section is! Map) continue;
      if (section['bodyBase64'] is String &&
          (section['bodyBase64'] as String).isNotEmpty) {
        continue;
      }
      final bodyText = section['bodyText'] ?? section['body'];
      if (bodyText is! String) continue;
      try {
        section['bodyBase64'] = base64.encode(utf8.encode(bodyText));
      } catch (_) {}
    }
  }
}

final mitmScriptServer = MitmScriptServer();
