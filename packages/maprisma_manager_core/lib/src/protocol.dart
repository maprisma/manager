import 'dart:convert';

/// The GUI↔core wire: one JSON object per request, see docs/protocol.md (same frame as Maprisma Theme).
const protocolVersion = 1;
const maxRequest = 64 * 1024;
const maxResponse = 4 * 1024 * 1024;

final class ServiceError extends StateError {
  ServiceError(this.code, [this.reason])
    : super('Service operation failed: $code');
  final String code;
  final String? reason;
}

final class Request {
  Request(this.id, this.method, this.params);
  final int id;
  final String method;
  final Map<String, dynamic> params;
  factory Request.decode(String frame) {
    if (utf8.encode(frame).length + 1 > maxRequest) {
      throw ServiceError('request_too_large');
    }
    final data = jsonDecode(frame);
    if (data is! Map ||
        data['id'] is! int ||
        data['id'] < 0 ||
        data['protocol'] != protocolVersion ||
        data['method'] is! String ||
        data.containsKey('params') && data['params'] is! Map) {
      throw const FormatException('Invalid request');
    }
    return Request(
      data['id'],
      data['method'],
      Map<String, dynamic>.from(data['params'] ?? {}),
    );
  }
}
