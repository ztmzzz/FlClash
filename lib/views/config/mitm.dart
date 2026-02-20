import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/mitm/mitm_kv_store.dart';
import 'package:fl_clash/mitm/mitm_manager.dart';
import 'package:fl_clash/mitm/mitm_script.dart';
import 'package:fl_clash/mitm/mitm_settings.dart';
import 'package:fl_clash/views/config/mitm_flows.dart';
import 'package:fl_clash/views/config/mitm_kv.dart';
import 'package:fl_clash/pages/editor.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/input.dart';
import 'package:fl_clash/widgets/list.dart';
import 'package:fl_clash/widgets/pop_scope.dart';
import 'package:fl_clash/widgets/scaffold.dart';
import 'package:flutter/material.dart';

String? _validateIntField(String? value, {required int min, required int max}) {
  if (value == null || value.trim().isEmpty) {
    return appLocalizations.emptyTip(appLocalizations.value);
  }
  final n = int.tryParse(value.trim());
  if (n == null) {
    return appLocalizations.numberTip(appLocalizations.value);
  }
  if (n < min) return '${appLocalizations.min}: $min';
  if (n > max) return 'Max: $max';
  return null;
}

class MitmConfigView extends StatefulWidget {
  const MitmConfigView({super.key});

  @override
  State<MitmConfigView> createState() => _MitmConfigViewState();
}

class _MitmConfigViewState extends State<MitmConfigView> {
  MitmSettings _settings = MitmSettings.defaults;
  bool _loading = true;

  bool _hasCert = false;
  bool _hasKey = false;
  List<MitmScript> _scripts = const [];
  MitmKvStats _kvStats = const MitmKvStats(entries: 0, bytes: 0);
  Timer? _autoApplyTimer;
  String? _lastAutoApplyError;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final s = await mitmManager.loadSettings();
    final cert = await mitmManager.readCaCertPem();
    final key = await mitmManager.readCaKeyPem();
    final scripts = await mitmManager.loadScripts();
    final kvStats = await mitmKvStore.stats();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _hasCert = (cert ?? '').trim().isNotEmpty;
      _hasKey = (key ?? '').trim().isNotEmpty;
      _scripts = scripts;
      _kvStats = kvStats;
      _loading = false;
    });
  }

  void _showAutoApplyError(String message) {
    if (_lastAutoApplyError == message) return;
    _lastAutoApplyError = message;
    globalState.showNotifier(message);
  }

  Future<void> _autoApplyNow() async {
    await mitmManager.saveSettings(_settings);
    if (!globalState.isStart) return;

    if (_settings.enable) {
      if (!_hasCert || !_hasKey) {
        _showAutoApplyError('CA 证书/私钥未导入');
        return;
      }
      final enabledScriptDomains = _scripts
          .where((e) => e.enable && e.content.trim().isNotEmpty)
          .expand((e) => e.domains)
          .toSet();
      if (enabledScriptDomains.isEmpty) {
        _showAutoApplyError('未配置可用脚本域名');
        return;
      }
    }

    final err = await mitmManager.applyToCore(settings: _settings);
    if (err != null) {
      _showAutoApplyError(err);
      return;
    }
    _lastAutoApplyError = null;
  }

  void _scheduleAutoApply({bool immediate = false}) {
    _autoApplyTimer?.cancel();
    if (immediate) {
      unawaited(_autoApplyNow());
      return;
    }
    _autoApplyTimer = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(_autoApplyNow()),
    );
  }

  void _updateSettings(MitmSettings next) {
    setState(() => _settings = next);
    _scheduleAutoApply();
  }

  Future<void> _importPem({required bool isCert}) async {
    final file = await picker.pickerFile(withData: true);
    if (file == null) return;
    final text = utf8.decode(file.bytes?.toList() ?? [], allowMalformed: true);
    if (isCert) {
      await mitmManager.writeCaCertPem(text);
    } else {
      await mitmManager.writeCaKeyPem(text);
    }
    if (!mounted) return;
    setState(() {
      if (isCert) {
        _hasCert = text.trim().isNotEmpty;
      } else {
        _hasKey = text.trim().isNotEmpty;
      }
    });
    _scheduleAutoApply(immediate: true);
  }

  Future<void> _clearPem({required bool isCert}) async {
    final res = await globalState.showMessage(
      message: TextSpan(text: isCert ? '确认删除 CA 证书？' : '确认删除 CA 私钥？'),
      title: 'MITM',
      confirmText: appLocalizations.confirm,
      cancelText: appLocalizations.cancel,
    );
    if (res != true) return;
    if (isCert) {
      await mitmManager.clearCaCert();
    } else {
      await mitmManager.clearCaKey();
    }
    if (!mounted) return;
    setState(() {
      if (isCert) {
        _hasCert = false;
      } else {
        _hasKey = false;
      }
    });
    _scheduleAutoApply(immediate: true);
  }

  Future<void> _openScripts() async {
    final res = await Navigator.of(context).push<List<MitmScript>>(
      MaterialPageRoute(builder: (_) => MitmScriptsView(scripts: _scripts)),
    );
    if (res == null) return;
    await mitmManager.saveScripts(res);
    if (!mounted) return;
    setState(() => _scripts = res);
    _scheduleAutoApply(immediate: true);
  }

  Future<void> _openKv() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const MitmKvView()));
    final kvStats = await mitmKvStore.stats();
    if (!mounted) return;
    setState(() => _kvStats = kvStats);
  }

  Future<void> _openFlows() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const MitmFlowsView()));
  }

  @override
  void dispose() {
    _autoApplyTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return BaseScaffold(
        title: 'MITM',
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final maxBytes = _settings.captureMaxBytes;
    final storeSize = _settings.storeSize;

    final items = <Widget>[
      ListItem.switchItem(
        title: const Text('Enable MITM'),
        subtitle: const Text('仅对启用脚本域名生效（HTTPS + HTTP/1.1）'),
        leading: const Icon(Icons.security),
        delegate: SwitchDelegate(
          value: _settings.enable,
          onChanged: (v) => _updateSettings(_settings.copyWith(enable: v)),
        ),
      ),
      ListItem(
        title: const Text('Import CA Cert (PEM)'),
        subtitle: Text(_hasCert ? '已导入' : '未导入'),
        leading: const Icon(Icons.badge),
        trailing: IconButton(
          onPressed: () => _clearPem(isCert: true),
          tooltip: appLocalizations.delete,
          icon: const Icon(Icons.delete_outline),
        ),
        onTap: () => _importPem(isCert: true),
      ),
      ListItem(
        title: const Text('Import CA Key (PEM)'),
        subtitle: Text(_hasKey ? '已导入' : '未导入'),
        leading: const Icon(Icons.key),
        trailing: IconButton(
          onPressed: () => _clearPem(isCert: false),
          tooltip: appLocalizations.delete,
          icon: const Icon(Icons.delete_outline),
        ),
        onTap: () => _importPem(isCert: false),
      ),
      ListItem.input(
        title: const Text('Body Limit (bytes)'),
        subtitle: const Text('超过上限：只转发，不做脚本处理'),
        leading: const Icon(Icons.data_usage),
        delegate: InputDelegate(
          title: 'Body Limit (bytes)',
          value: '$maxBytes',
          resetValue: '${MitmSettings.defaults.captureMaxBytes}',
          validator: (v) =>
              _validateIntField(v, min: 1024, max: 1024 * 1024 * 8),
          onChanged: (value) {
            final v = int.tryParse(value?.trim() ?? '');
            if (v == null) return;
            _updateSettings(_settings.copyWith(captureMaxBytes: v));
          },
        ),
      ),
      ListItem.input(
        title: const Text('Flow Store Size'),
        subtitle: const Text('内存保存的 HTTP 流数量（环形缓冲）'),
        leading: const Icon(Icons.storage),
        delegate: InputDelegate(
          title: 'Flow Store Size',
          value: '$storeSize',
          resetValue: '${MitmSettings.defaults.storeSize}',
          validator: (v) => _validateIntField(v, min: 50, max: 2000),
          onChanged: (value) {
            final v = int.tryParse(value?.trim() ?? '');
            if (v == null) return;
            _updateSettings(_settings.copyWith(storeSize: v));
          },
        ),
      ),
      ListItem.switchItem(
        title: const Text('Skip Upstream TLS Verify'),
        subtitle: const Text('上游证书校验失败时仍可 MITM（不推荐）'),
        leading: const Icon(Icons.gpp_bad),
        delegate: SwitchDelegate(
          value: _settings.skipVerify,
          onChanged: (v) => _updateSettings(_settings.copyWith(skipVerify: v)),
        ),
      ),
      const Divider(height: 0),
      ListItem(
        title: const Text('Scripts'),
        subtitle: Text(
          _scripts.isEmpty
              ? '未配置'
              : '${_scripts.length} 个（启用 ${_scripts.where((e) => e.enable).length}）',
        ),
        leading: const Icon(Icons.code),
        onTap: _openScripts,
      ),
      ListItem(
        title: const Text('KV Store'),
        subtitle: Text('${_kvStats.entries} entries · ${_kvStats.bytes} bytes'),
        leading: const Icon(Icons.dataset_outlined),
        onTap: _openKv,
      ),
      ListItem(
        title: const Text('Flow History'),
        subtitle: const Text('查看抓取到的 HTTP 请求/响应'),
        leading: const Icon(Icons.history),
        onTap: _openFlows,
      ),
    ];

    return BaseScaffold(
      title: 'MITM',
      body: generateListView(
        items.separated(const Divider(height: 0)).toList(),
      ),
    );
  }
}

class MitmScriptsView extends StatefulWidget {
  final List<MitmScript> scripts;

  const MitmScriptsView({super.key, required this.scripts});

  @override
  State<MitmScriptsView> createState() => _MitmScriptsViewState();
}

class _MitmScriptsViewState extends State<MitmScriptsView> {
  late final List<MitmScript> _scripts = List.of(widget.scripts);

  Future<void> _add() async {
    final name = await globalState.showCommonDialog<String>(
      child: const InputDialog(title: 'Script name', value: 'Script'),
    );
    if (name == null) return;
    setState(() {
      _scripts.add(
        MitmScript(
          id: utils.id,
          name: name,
          enable: true,
          domainsText: '',
          timeoutMs: MitmScript.defaultTimeoutMs,
          content: '''
function handle(ctx) {
  // ctx.phase = "request" | "response"
  return {};
}
''',
        ),
      );
    });
  }

  Future<void> _edit(MitmScript s) async {
    final res = await Navigator.of(context).push<MitmScript>(
      MaterialPageRoute(builder: (_) => MitmScriptEditView(script: s)),
    );
    if (res == null) return;
    setState(() {
      final idx = _scripts.indexWhere((e) => e.id == s.id);
      if (idx >= 0) _scripts[idx] = res;
    });
  }

  Future<void> _delete(MitmScript s) async {
    final ok = await globalState.showMessage(
      title: 'Delete',
      message: TextSpan(text: s.name),
    );
    if (ok != true) return;
    setState(() => _scripts.removeWhere((e) => e.id == s.id));
  }

  @override
  Widget build(BuildContext context) {
    return CommonPopScope(
      onPop: (_) {
        Navigator.of(context).pop(_scripts);
        return false;
      },
      child: BaseScaffold(
        title: 'Scripts',
        actions: [IconButton(onPressed: _add, icon: const Icon(Icons.add))],
        body: generateListView(
          _scripts
              .map<Widget>(
                (s) => ListItem(
                  leading: const Icon(Icons.code),
                  title: Text(s.name),
                  subtitle: Text(
                    '${s.enable ? "ON" : "OFF"} · domains ${s.domains.length} · timeout ${s.timeoutMs}ms',
                  ),
                  trailing: IconButton(
                    onPressed: () => _delete(s),
                    icon: const Icon(Icons.delete_outline),
                  ),
                  onTap: () => _edit(s),
                ),
              )
              .separated(const Divider(height: 0))
              .toList(),
        ),
      ),
    );
  }
}

class MitmScriptEditView extends StatefulWidget {
  final MitmScript script;

  const MitmScriptEditView({super.key, required this.script});

  @override
  State<MitmScriptEditView> createState() => _MitmScriptEditViewState();
}

class _MitmScriptEditViewState extends State<MitmScriptEditView> {
  late MitmScript _script = widget.script;

  Future<void> _editDomains() async {
    final domains = _script.domains;
    final items = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => ListInputPage(
          title: 'Domains',
          items: domains,
          titleBuilder: (item) => Text(item),
          valueLabel: 'domain',
        ),
      ),
    );
    if (items == null) return;
    setState(() => _script = _script.copyWith(domainsText: items.join('\n')));
  }

  Future<void> _editContent() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditorPage(
          title: _script.name,
          content: _script.content,
          languages: const [Language.javaScript],
          onSave: (_, _, content) {
            setState(() => _script = _script.copyWith(content: content));
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _script.enable;
    final domainsCount = _script.domains.length;
    return BaseScaffold(
      title: _script.name,
      actions: [
        IconButton(
          onPressed: () => Navigator.of(context).pop(_script),
          icon: const Icon(Icons.check),
        ),
      ],
      body: generateListView(
        <Widget>[
          ListItem.switchItem(
            leading: const Icon(Icons.toggle_on),
            title: const Text('Enable'),
            delegate: SwitchDelegate(
              value: enabled,
              onChanged: (v) =>
                  setState(() => _script = _script.copyWith(enable: v)),
            ),
          ),
          ListItem(
            leading: const Icon(Icons.public),
            title: const Text('Domains'),
            subtitle: Text(domainsCount == 0 ? '未配置' : '$domainsCount 条'),
            onTap: _editDomains,
          ),
          ListItem.input(
            leading: const Icon(Icons.timer),
            title: const Text('Timeout (ms)'),
            delegate: InputDelegate(
              title: 'Timeout (ms)',
              value: '${_script.timeoutMs}',
              resetValue: '${MitmScript.defaultTimeoutMs}',
              validator: (v) => _validateIntField(v, min: 50, max: 5000),
              onChanged: (value) {
                final n = int.tryParse(value?.trim() ?? '');
                if (n == null) return;
                setState(() => _script = _script.copyWith(timeoutMs: n));
              },
            ),
          ),
          ListItem(
            leading: const Icon(Icons.edit),
            title: const Text('Edit Script'),
            subtitle: Text(
              _script.content.trim().isEmpty
                  ? '空脚本'
                  : '长度 ${_script.content.length}',
            ),
            onTap: _editContent,
          ),
        ].separated(const Divider(height: 0)).toList(),
      ),
    );
  }
}
