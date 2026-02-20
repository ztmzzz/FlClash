import 'package:fl_clash/mitm/mitm_text.dart';

class MitmScript {
  final String id;
  final String name;
  final bool enable;
  final String domainsText;
  final int timeoutMs;
  final String content;

  const MitmScript({
    required this.id,
    required this.name,
    required this.enable,
    required this.domainsText,
    required this.timeoutMs,
    required this.content,
  });

  static const defaultTimeoutMs = 500;

  List<String> get domains {
    return parseMitmDomainsText(domainsText);
  }

  int get effectiveTimeoutMs {
    return timeoutMs <= 0 ? defaultTimeoutMs : timeoutMs;
  }

  MitmScript copyWith({
    String? id,
    String? name,
    bool? enable,
    String? domainsText,
    int? timeoutMs,
    String? content,
  }) {
    return MitmScript(
      id: id ?? this.id,
      name: name ?? this.name,
      enable: enable ?? this.enable,
      domainsText: domainsText ?? this.domainsText,
      timeoutMs: timeoutMs ?? this.timeoutMs,
      content: content ?? this.content,
    );
  }

  factory MitmScript.fromJson(Map<String, Object?> json) {
    return MitmScript(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Script',
      enable: json['enable'] as bool? ?? false,
      domainsText: json['domainsText'] as String? ?? '',
      timeoutMs: json['timeoutMs'] as int? ?? defaultTimeoutMs,
      content: json['content'] as String? ?? '',
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'enable': enable,
      'domainsText': domainsText,
      'timeoutMs': timeoutMs,
      'content': content,
    };
  }
}
