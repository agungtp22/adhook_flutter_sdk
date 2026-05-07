import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'src/models/message.dart';
import 'src/models/style.dart';
import 'src/widgets/chat_window.dart';
import 'src/services/local_db.dart';

export 'src/models/message.dart';
export 'src/models/style.dart';
export 'src/widgets/chat_window.dart';

enum AdhookConnectionStatus { connecting, connected, disconnected }

class AdhookChat {
  static final AdhookChat _instance = AdhookChat._internal();
  factory AdhookChat() => _instance;
  AdhookChat._internal();

  String? _apiKey;
  String? _baseUrl;
  String? _widgetKey;
  String? _sessionId;
  String? _userName;
  String? _userEmail;
  String? _userPhone;
  bool _debugMode = false;
  
  WebSocketChannel? _channel;
  bool _isConnected = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  
  final AdhookLocalDb _localDb = AdhookLocalDb();
  
  final List<AdhookMessage> _messages = [];

  final _messageController = StreamController<List<AdhookMessage>>.broadcast();
  Stream<List<AdhookMessage>> get messageHistory => _messageController.stream;

  final _typingController = StreamController<bool>.broadcast();
  Stream<bool> get agentTypingStatus => _typingController.stream;

  final _statusController = StreamController<AdhookConnectionStatus>.broadcast();
  Stream<AdhookConnectionStatus> get connectionStatus => _statusController.stream;

  // New: Error stream for informing developers/users
  final _errorController = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorController.stream;

  List<AdhookMessage> get currentMessages => List.unmodifiable(_messages);
  String? get baseUrl => _baseUrl;
  bool get hasUserInfo => _userName != null && _userName!.isNotEmpty;

  static Future<void> init({
    required String apiKey,
    required String baseUrl,
    required String widgetKey,
    String? name,
    String? email,
    String? phone,
    bool debugMode = false,
  }) async {
    _instance._apiKey = apiKey;
    _instance._baseUrl = baseUrl;
    _instance._widgetKey = widgetKey;
    _instance._userName = name;
    _instance._userEmail = email;
    _instance._userPhone = phone;
    _instance._debugMode = debugMode;
    await _instance._loadSession();
  }

  void _log(String message) {
    if (_debugMode) print("[AdhookSDK] $message");
  }

  void setUserInfo({String? name, String? email, String? phone}) {
    _userName = name;
    _userEmail = email;
    _userPhone = phone;
  }

  Future<void> _loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    _sessionId = prefs.getString('adhook_session_id');
  }

  Future<void> _saveSession(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('adhook_session_id', sessionId);
    _sessionId = sessionId;
  }

  Future<void> connect() async {
    if (_baseUrl == null) {
      _errorController.add("SDK not initialized. Call init() first.");
      return;
    }

    _log("Connecting to WebSocket...");
    _statusController.add(AdhookConnectionStatus.connecting);

    try {
      // Load from local DB first for instant display (Mobile only)
      if (!kIsWeb) {
        final localMsgs = await _localDb.getMessages();
        if (localMsgs.isNotEmpty) {
          _messages.clear();
          _messages.addAll(localMsgs);
          _messageController.add(currentMessages);
        }
      }

      if (_sessionId == null) {
        await _createNewSession();
      } else if (_messages.isEmpty) {
        await _fetchHistory();
      }

      final wsUrl = '${_baseUrl!.replaceFirst('http', 'ws')}/ws/widget/$_sessionId';
      _log("Handshaking with URL: $wsUrl");
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      
      _channel!.stream.listen(
        (data) {
          final decoded = jsonDecode(data);
          _log("Received: $data");

          if (decoded['type'] == 'connected') {
            _isConnected = true;
            _reconnectAttempts = 0;
            _statusController.add(AdhookConnectionStatus.connected);
          }

          if (decoded['type'] == 'message') {
            final msgData = decoded['data'];
            final msg = AdhookMessage.fromJson(msgData);
            if (!_messages.any((m) => m.id == msg.id && msg.id != 0)) {
              _messages.add(msg);
              _messageController.add(currentMessages);
              if (!kIsWeb) _localDb.saveMessage(msg); // Persistence for mobile
            }
            _typingController.add(false);
          }

          if (decoded['type'] == 'typing') {
            _typingController.add(decoded['data']['is_typing'] ?? false);
          }

          if (decoded['type'] == 'read') {
            for (var m in _messages) { if (m.sender == AdhookSender.visitor) m.isRead = true; }
            _messageController.add(currentMessages);
          }
          
          if (decoded['type'] == 'error') {
            _errorController.add(decoded['error'] ?? "Unknown WebSocket error");
          }
        },
        onDone: () {
          _isConnected = false;
          _statusController.add(AdhookConnectionStatus.disconnected);
          _attemptReconnect();
        },
        onError: (error) {
          _isConnected = false;
          _statusController.add(AdhookConnectionStatus.disconnected);
          _attemptReconnect();
        },
      );
    } catch (e) {
      _statusController.add(AdhookConnectionStatus.disconnected);
      _errorController.add(e.toString());
    }
  }

  void _attemptReconnect() {
    if (_reconnectAttempts > 5) return;
    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    _reconnectTimer = Timer(Duration(seconds: _reconnectAttempts * 2), () => connect());
  }

  Future<void> _fetchHistory() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/widget/messages/$_sessionId'),
        headers: {'Authorization': 'Bearer $_apiKey'},
      );

      if (response.statusCode == 200) {
        final dynamic decoded = jsonDecode(response.body);
        List<dynamic> items = [];
        if (decoded is List) {
          items = decoded;
        } else if (decoded is Map && decoded['messages'] is List) {
          items = decoded['messages'];
        }

        _messages.clear();
        for (var item in items) { 
          final msg = AdhookMessage.fromJson(item);
          _messages.add(msg);
          if (!kIsWeb) _localDb.saveMessage(msg); 
        }
        _messageController.add(currentMessages);
      } else {
        _handleApiError(response);
      }
    } catch (e) {
      _errorController.add("History fetch failed: $e");
    }
  }

  Future<void> _createNewSession() async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/widget/init'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_apiKey',
        },
        body: jsonEncode({
          "widget_key": _widgetKey,
          "visitor_id": "visitor-${DateTime.now().millisecondsSinceEpoch}",
          "name": _userName,
          "email": _userEmail,
          "phone": _userPhone,
          "page_url": "flutter-app",
          "referrer": "adhook-sdk",
        }),
      );
      
      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        await _saveSession(data['session_id']);
      } else {
        _handleApiError(response);
      }
    } catch (e) {
      _errorController.add("Session creation failed: $e");
      rethrow;
    }
  }

  void _handleApiError(http.Response response) {
    try {
      final data = jsonDecode(response.body);
      final errorMsg = data['error'] ?? "Request failed with status ${response.statusCode}";
      _errorController.add(errorMsg);
    } catch (_) {
      _errorController.add("Request failed with status ${response.statusCode}");
    }
  }

  void sendMessage(String text, {int? replyToId}) {
    if (!_isConnected || _channel == null) return;
    _channel!.sink.add(jsonEncode({"type": "message", "data": {"message_text": text, "reply_to_id": replyToId}}));
    sendTypingStatus(false);
  }

  void sendTypingStatus(bool isTyping) {
    if (!_isConnected || _channel == null) return;
    _channel!.sink.add(jsonEncode({"type": "typing", "data": {"is_typing": isTyping}}));
  }

  void sendLocation(double lat, double lng) {
    if (!_isConnected || _channel == null) return;
    _channel!.sink.add(jsonEncode({"type": "location", "data": {"latitude": lat, "longitude": lng}}));
  }

  void submitRating(int rating, String comment) {
    if (!_isConnected || _channel == null) return;
    _channel!.sink.add(jsonEncode({"type": "rating", "data": {"rating": rating, "comment": comment}}));
  }

  Future<void> pickAndUploadFile() async {
    if (_sessionId == null) return;
    final result = await FilePicker.platform.pickFiles(type: FileType.any, allowMultiple: false);
    if (result != null) {
      final file = result.files.single;
      final request = http.MultipartRequest('POST', Uri.parse('$_baseUrl/api/widget/upload'));
      request.fields['session_id'] = _sessionId!;
      request.headers['Authorization'] = 'Bearer $_apiKey';
      if (file.bytes != null) {
        request.files.add(http.MultipartFile.fromBytes('file', file.bytes!, filename: file.name));
      } else if (file.path != null) {
        request.files.add(await http.MultipartFile.fromPath('file', file.path!, filename: file.name));
      }
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      if (response.statusCode != 200) _handleApiError(response);
    }
  }

  Future<void> uploadFileFromPath(String path) async {
    if (_sessionId == null) return;
    final request = http.MultipartRequest('POST', Uri.parse('$_baseUrl/api/widget/upload'));
    request.fields['session_id'] = _sessionId!;
    request.headers['Authorization'] = 'Bearer $_apiKey';
    request.files.add(await http.MultipartFile.fromPath('file', path));
    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode != 200) _handleApiError(response);
  }

  void dispose() {
    _channel?.sink.close();
    _reconnectTimer?.cancel();
    _messageController.close();
    _typingController.close();
    _statusController.close();
    _errorController.close();
  }
}
