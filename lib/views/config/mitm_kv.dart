import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/mitm/mitm_kv_store.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/dialog.dart';
import 'package:fl_clash/widgets/list.dart';
import 'package:fl_clash/widgets/scaffold.dart';
import 'package:flutter/material.dart';

class MitmKvView extends StatefulWidget {
  const MitmKvView({super.key});

  @override
  State<MitmKvView> createState() => _MitmKvViewState();
}

class _MitmKvViewState extends State<MitmKvView> {
  bool _loading = true;
  Map<String, dynamic> _kv = const {};
  MitmKvStats _stats = const MitmKvStats(entries: 0, bytes: 0);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final kv = await mitmKvStore.snapshot();
    final stats = await mitmKvStore.stats();
    if (!mounted) return;
    setState(() {
      _kv = kv;
      _stats = stats;
      _loading = false;
    });
  }

  String _formatValue(dynamic v) {
    if (v == null) return 'null';
    if (v is String) return v;
    try {
      return json.encode(v);
    } catch (_) {
      return v.toString();
    }
  }

  String _previewValue(dynamic v) {
    final s = _formatValue(v);
    if (s.length <= 80) return s;
    return '${s.substring(0, 80)}...';
  }

  Future<void> _upsert({String? key, dynamic current}) async {
    final initialKey = (key ?? '').trim();
    final initialValue = current == null ? '' : _formatValue(current);

    final res = await globalState.showCommonDialog<_KvEditResult>(
      child: _KvEditDialog(
        keyText: initialKey.isEmpty ? 'key' : initialKey,
        valueText: initialValue,
        lockKey: initialKey.isNotEmpty,
      ),
    );
    if (res == null) return;

    dynamic value;
    final raw = res.valueText.trim();
    if (raw.isEmpty) {
      value = '';
    } else {
      try {
        value = json.decode(raw);
      } catch (_) {
        value = res.valueText;
      }
    }

    final err = await mitmKvStore.upsert(res.keyText, value);
    if (err != null) {
      globalState.showNotifier(err);
      return;
    }
    await _load();
  }

  Future<void> _delete(String key) async {
    final ok = await globalState.showMessage(
      title: 'Delete',
      message: TextSpan(text: key),
    );
    if (ok != true) return;
    await mitmKvStore.remove(key);
    await _load();
  }

  Future<void> _clearAll() async {
    final ok = await globalState.showMessage(
      title: 'Clear',
      message: const TextSpan(text: 'Clear all KV entries?'),
    );
    if (ok != true) return;
    await mitmKvStore.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _kv.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return BaseScaffold(
      title: 'KV Store',
      actions: [
        IconButton(onPressed: _clearAll, icon: const Icon(Icons.delete_sweep)),
        IconButton(onPressed: () => _upsert(), icon: const Icon(Icons.add)),
      ],
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : generateListView(
              <Widget>[
                ListItem(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Stats'),
                  subtitle: Text('${_stats.entries} entries · ${_stats.bytes} bytes'),
                ),
                const Divider(height: 0),
                if (items.isEmpty)
                  const ListItem(
                    leading: Icon(Icons.inbox_outlined),
                    title: Text('Empty'),
                    subtitle: Text('No KV entries'),
                  )
                else
                  ...items.map(
                    (e) => ListItem(
                      leading: const Icon(Icons.key),
                      title: Text(e.key),
                      subtitle: Text(_previewValue(e.value)),
                      trailing: IconButton(
                        onPressed: () => _delete(e.key),
                        icon: const Icon(Icons.delete_outline),
                      ),
                      onTap: () => _upsert(key: e.key, current: e.value),
                    ),
                  ),
              ].separated(const Divider(height: 0)).toList(),
            ),
    );
  }
}

class _KvEditResult {
  final String keyText;
  final String valueText;

  const _KvEditResult({required this.keyText, required this.valueText});
}

class _KvEditDialog extends StatefulWidget {
  final String keyText;
  final String valueText;
  final bool lockKey;

  const _KvEditDialog({
    required this.keyText,
    required this.valueText,
    required this.lockKey,
  });

  @override
  State<_KvEditDialog> createState() => _KvEditDialogState();
}

class _KvEditDialogState extends State<_KvEditDialog> {
  late final TextEditingController _keyController = TextEditingController(
    text: widget.keyText,
  );
  late final TextEditingController _valueController = TextEditingController(
    text: widget.valueText,
  );

  @override
  void dispose() {
    _keyController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CommonDialog(
      title: 'Edit KV',
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(appLocalizations.cancel),
        ),
        TextButton(
          onPressed: () {
            final k = _keyController.text.trim();
            if (k.isEmpty) {
              globalState.showNotifier('key is empty');
              return;
            }
            Navigator.of(context).pop(
              _KvEditResult(
                keyText: k,
                valueText: _valueController.text,
              ),
            );
          },
          child: Text(appLocalizations.confirm),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _keyController,
            enabled: !widget.lockKey,
            decoration: const InputDecoration(labelText: 'Key'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _valueController,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'Value (JSON or plain text)',
            ),
          ),
        ],
      ),
    );
  }
}
