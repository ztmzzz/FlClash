import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/mitm/mitm_storage.dart';

class MitmKvStats {
  final int entries;
  final int bytes;

  const MitmKvStats({required this.entries, required this.bytes});
}

class MitmKvStore {
  Map<String, dynamic> _cache = const {};
  bool _loaded = false;
  Future<void> _seq = Future.value();

  static const int maxEntries = 200;
  static const int maxBytes = 128 * 1024;

  Future<File> _file() => mitmFile('kv.json');

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

  int _encodedBytes(Map<String, dynamic> map) {
    try {
      return utf8.encode(json.encode(map)).length;
    } catch (_) {
      return 0;
    }
  }

  Map<String, dynamic> _clone(Map<String, dynamic> inMap) {
    return json.decode(json.encode(inMap)) as Map<String, dynamic>;
  }

  String? _validateLimits(Map<String, dynamic> map) {
    if (map.length > maxEntries) {
      return 'kv entries limit exceeded ($maxEntries)';
    }
    if (_encodedBytes(map) > maxBytes) {
      return 'kv bytes limit exceeded ($maxBytes)';
    }
    return null;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final f = await _file();
    if (!await f.exists()) {
      _cache = const {};
      _loaded = true;
      return;
    }
    try {
      final raw = await f.readAsString();
      final decoded = json.decode(raw);
      if (decoded is Map) {
        _cache = Map<String, dynamic>.from(decoded);
      } else {
        _cache = const {};
      }
    } catch (_) {
      _cache = const {};
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    final f = await _file();
    await f.safeWriteAsString(json.encode(_cache));
  }

  Future<Map<String, dynamic>> snapshot() {
    return _serialize(() async {
      await _ensureLoaded();
      return _clone(_cache);
    });
  }

  Future<MitmKvStats> stats() {
    return _serialize(() async {
      await _ensureLoaded();
      return MitmKvStats(entries: _cache.length, bytes: _encodedBytes(_cache));
    });
  }

  Future<String?> upsert(String key, dynamic value) {
    return _serialize(() async {
      await _ensureLoaded();
      final k = key.trim();
      if (k.isEmpty) return 'key is empty';
      if (k.length > 128) return 'key too long';

      final next = Map<String, dynamic>.from(_cache);
      next[k] = value;

      final limitsErr = _validateLimits(next);
      if (limitsErr != null) return limitsErr;

      _cache = next;
      await _persist();
      return null;
    });
  }

  Future<String?> remove(String key) {
    return _serialize(() async {
      await _ensureLoaded();
      final k = key.trim();
      if (k.isEmpty) return null;
      if (!_cache.containsKey(k)) return null;
      final next = Map<String, dynamic>.from(_cache)..remove(k);
      _cache = next;
      await _persist();
      return null;
    });
  }

  Future<void> clear() {
    return _serialize(() async {
      await _ensureLoaded();
      _cache = const {};
      await _persist();
    });
  }

  Future<String?> applyMutations({
    Map<String, dynamic>? set,
    List<String>? remove,
  }) {
    return _serialize(() async {
      await _ensureLoaded();
      final next = Map<String, dynamic>.from(_cache);

      if (remove != null) {
        for (final k in remove) {
          final key = k.trim();
          if (key.isEmpty) continue;
          next.remove(key);
        }
      }

      if (set != null) {
        for (final e in set.entries) {
          final key = e.key.trim();
          if (key.isEmpty) continue;
          if (key.length > 128) return 'key too long: $key';
          next[key] = e.value;
        }
      }

      final limitsErr = _validateLimits(next);
      if (limitsErr != null) return limitsErr;

      _cache = next;
      await _persist();
      return null;
    });
  }
}

final mitmKvStore = MitmKvStore();
