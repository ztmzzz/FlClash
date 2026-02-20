class MitmSettings {
  final bool enable;
  final int captureMaxBytes;
  final int storeSize;
  final bool skipVerify;

  const MitmSettings({
    required this.enable,
    required this.captureMaxBytes,
    required this.storeSize,
    required this.skipVerify,
  });

  static const defaults = MitmSettings(
    enable: false,
    captureMaxBytes: 64 * 1024,
    storeSize: 200,
    skipVerify: false,
  );

  MitmSettings copyWith({
    bool? enable,
    int? captureMaxBytes,
    int? storeSize,
    bool? skipVerify,
  }) {
    return MitmSettings(
      enable: enable ?? this.enable,
      captureMaxBytes: captureMaxBytes ?? this.captureMaxBytes,
      storeSize: storeSize ?? this.storeSize,
      skipVerify: skipVerify ?? this.skipVerify,
    );
  }

  factory MitmSettings.fromJson(Map<String, Object?>? json) {
    if (json == null) return defaults;
    return MitmSettings(
      enable: json['enable'] as bool? ?? defaults.enable,
      captureMaxBytes:
          json['captureMaxBytes'] as int? ?? defaults.captureMaxBytes,
      storeSize: json['storeSize'] as int? ?? defaults.storeSize,
      skipVerify: json['skipVerify'] as bool? ?? defaults.skipVerify,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'enable': enable,
      'captureMaxBytes': captureMaxBytes,
      'storeSize': storeSize,
      'skipVerify': skipVerify,
    };
  }
}
