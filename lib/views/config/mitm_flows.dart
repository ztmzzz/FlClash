import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/list.dart';
import 'package:fl_clash/widgets/scaffold.dart';
import 'package:flutter/material.dart';

class MitmFlowsView extends StatefulWidget {
  const MitmFlowsView({super.key});

  @override
  State<MitmFlowsView> createState() => _MitmFlowsViewState();
}

class _MitmFlowsViewState extends State<MitmFlowsView> {
  bool _loading = true;
  List<Map<String, dynamic>> _flows = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  String _formatTime(dynamic value) {
    if (value is! String || value.isEmpty) return '-';
    try {
      final t = DateTime.parse(value).toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    } catch (_) {
      return value;
    }
  }

  Future<void> _load() async {
    List<Map<String, dynamic>> list = const [];
    try {
      final raw = await coreController.getHttpFlows();
      list = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    } catch (e) {
      globalState.showNotifier('加载 Flow 失败: $e');
    }
    if (!mounted) return;
    setState(() {
      _flows = list;
      _loading = false;
    });
  }

  Future<void> _clearAll() async {
    final ok = await globalState.showMessage(
      title: 'MITM',
      message: const TextSpan(text: 'Clear all HTTP flows?'),
      confirmText: 'Clear',
    );
    if (ok != true) return;
    final cleared = await coreController.clearHttpFlows();
    if (!cleared) {
      globalState.showNotifier('清空失败');
      return;
    }
    await _load();
  }

  Future<void> _openDetail(String id) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => MitmFlowDetailView(id: id)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const BaseScaffold(
        title: 'HTTP Flows',
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final items = <Widget>[
      ListItem(
        leading: const Icon(Icons.info_outline),
        title: const Text('History'),
        subtitle: Text('共 ${_flows.length} 条，最新在上方'),
      ),
      if (_flows.isEmpty)
        const ListItem(
          leading: Icon(Icons.inbox_outlined),
          title: Text('Empty'),
          subtitle: Text('暂无 HTTP 流量记录'),
        )
      else
        ..._flows.map((item) {
          final id = _valueToText(item['id']);
          final method = _valueToText(item['method']);
          final host = _valueToText(item['host']);
          final path = _valueToText(item['path']);
          final status = item['status'];
          final statusText = status is int && status > 0
              ? '$status'
              : 'pending';
          final error = _valueToText(item['error']);
          final truncated = item['truncated'] == true;
          final tail = <String>[
            _formatTime(item['time']),
            statusText,
            if (truncated) 'truncated',
            if (error.isNotEmpty) error,
          ].join(' · ');
          return ListItem(
            leading: const Icon(Icons.http),
            title: Text('$method $host'),
            subtitle: Text('$path\n$tail'),
            onTap: id.isEmpty ? null : () => _openDetail(id),
          );
        }),
    ];

    return BaseScaffold(
      title: 'HTTP Flows',
      actions: [
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        IconButton(onPressed: _clearAll, icon: const Icon(Icons.delete_sweep)),
      ],
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: items.length,
          padding: const EdgeInsets.only(bottom: 16),
          separatorBuilder: (_, _) => const Divider(height: 0),
          itemBuilder: (_, index) => items[index],
        ),
      ),
    );
  }
}

class MitmFlowDetailView extends StatefulWidget {
  final String id;

  const MitmFlowDetailView({super.key, required this.id});

  @override
  State<MitmFlowDetailView> createState() => _MitmFlowDetailViewState();
}

class _MitmFlowDetailViewState extends State<MitmFlowDetailView> {
  bool _loading = true;
  Map<String, dynamic>? _flow;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    Map<String, dynamic>? flow;
    try {
      flow = await coreController.getHttpFlow(widget.id);
    } catch (e) {
      globalState.showNotifier('加载详情失败: $e');
    }
    if (!mounted) return;
    setState(() {
      _flow = flow;
      _loading = false;
    });
  }

  Widget _section({
    required String title,
    required IconData icon,
    required String text,
  }) {
    return Column(
      children: [
        ListItem(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text('${text.length} chars'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
            ),
            child: SelectionArea(
              child: Text(
                text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const BaseScaffold(
        title: 'Flow Detail',
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_flow == null) {
      return BaseScaffold(
        title: 'Flow Detail',
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
        body: generateListView(const [
          ListItem(
            leading: Icon(Icons.error_outline),
            title: Text('Not Found'),
            subtitle: Text('该 Flow 可能已被 ring buffer 覆盖'),
          ),
        ]),
      );
    }

    final summary = _map(_flow!['summary']);
    final request = _map(_flow!['request']);
    final response = _map(_flow!['response']);

    final summaryText = [
      'id: ${_valueToText(summary['id'])}',
      'time: ${_valueToText(summary['time'])}',
      'scheme: ${_valueToText(summary['scheme'])}',
      'method: ${_valueToText(summary['method'])}',
      'host: ${_valueToText(summary['host'])}',
      'path: ${_valueToText(summary['path'])}',
      'status: ${_valueToText(summary['status'])}',
      'error: ${_valueToText(summary['error'])}',
      'src-addr: ${_valueToText(summary['src-addr'])}',
      'dst-addr: ${_valueToText(summary['dst-addr'])}',
      'truncated: ${summary['truncated'] == true}',
    ].join('\n');

    final items = <Widget>[
      _section(title: 'Summary', icon: Icons.info_outline, text: summaryText),
      _section(
        title: 'Request Headers',
        icon: Icons.outbox_outlined,
        text: _formatHeaders(request['header']),
      ),
      _section(
        title: 'Request Body',
        icon: Icons.description_outlined,
        text: _decodeBody(request['body']),
      ),
      _section(
        title: 'Response Headers',
        icon: Icons.inbox_outlined,
        text: _formatHeaders(response['header']),
      ),
      _section(
        title: 'Response Body',
        icon: Icons.description,
        text: _decodeBody(response['body']),
      ),
    ];

    return BaseScaffold(
      title: 'Flow Detail',
      actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
      body: generateListView(items),
    );
  }
}

Map<String, dynamic> _map(dynamic value) {
  if (value is! Map) return const {};
  return Map<String, dynamic>.from(value);
}

String _valueToText(dynamic value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is List) return value.map((e) => '$e').join(', ');
  return '$value';
}

String _formatHeaders(dynamic value) {
  final map = _map(value);
  if (map.isEmpty) return '(empty)';
  final entries = map.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  return entries.map((e) => '${e.key}: ${_valueToText(e.value)}').join('\n');
}

String _decodeBody(dynamic value) {
  final raw = _valueToText(value);
  if (raw.isEmpty) return '(empty)';
  try {
    final bytes = base64.decode(raw);
    if (bytes.isEmpty) return '(empty)';
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return raw;
  }
}
