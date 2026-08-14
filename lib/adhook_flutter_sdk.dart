import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
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

  final _errorController = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorController.stream;

  final _callEventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get callEventStream => _callEventController.stream;

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
      // Load from local DB first for instant display
      if (!kIsWeb) {
        final localMsgs = await _localDb.getMessages();
        if (localMsgs.isNotEmpty) {
          _messages.clear();
          _messages.addAll(localMsgs);
          _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          _messageController.add(currentMessages);
        }
      }

      if (_sessionId == null) {
        await _createNewSession();
      } else {
        await _fetchHistory();
      }

      final wsUrl = '${_baseUrl!.replaceFirst('http', 'ws')}/ws/widget/$_sessionId';
      _log("Handshaking with URL: $wsUrl");
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      
      // Perform handshake
      _channel!.sink.add(jsonEncode({
        "type": "widget",
        "session_id": _sessionId,
        "widget_key": _widgetKey
      }));

      _channel!.stream.listen(
        (data) {
          final decoded = jsonDecode(data);
          _log("Received: $data");

          final eventType = decoded['event'] ?? decoded['type'];

          if (eventType == 'connected') {
            _isConnected = true;
            _reconnectAttempts = 0;
            _statusController.add(AdhookConnectionStatus.connected);
          }

          if (eventType == 'new_message' || eventType == 'message') {
            final rawData = decoded['data'] is Map ? decoded['data'] : decoded['message'];
            final Map<String, dynamic>? msgData = rawData is Map<String, dynamic>
                ? rawData
                : (rawData is Map ? Map<String, dynamic>.from(rawData) : null);

            if (msgData != null) {
              final msg = AdhookMessage.fromJson(msgData);
              if (!_messages.any((m) => m.id == msg.id && msg.id.isNotEmpty)) {
                _messages.add(msg);
                _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
                _messageController.add(currentMessages);
                if (!kIsWeb) _localDb.saveMessage(msg);
              }
            }
            _typingController.add(false);
          }

          if (eventType == 'agent_assigned' || eventType == 'session_assigned') {
            final systemMsg = AdhookMessage(
              id: 'sys-${DateTime.now().millisecondsSinceEpoch}',
              content: 'Sesi dialihkan ke Agen: ${decoded['agent_name'] ?? 'Support Agent'}',
              sender: AdhookSender.agent,
              createdAt: DateTime.now(),
              type: 'TEXT'
            );
            _messages.add(systemMsg);
            _messageController.add(currentMessages);
          }

          if (eventType == 'system' || eventType == 'conversation_closed' || eventType == 'conversation_ended') {
            final rawData = decoded['data'] is Map ? decoded['data'] : decoded;
            final String text = (rawData['message_text'] ?? rawData['content'] ?? rawData['text'] ?? 'conversation_closed').toString();

            final sysMsg = AdhookMessage(
              id: 'sys-${DateTime.now().millisecondsSinceEpoch}',
              content: text.isNotEmpty ? text : 'conversation_closed',
              sender: AdhookSender.system,
              createdAt: DateTime.now(),
              type: 'system'
            );
            _messages.add(sysMsg);
            _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
            _messageController.add(currentMessages);
            _log("Received system/close event: $text");
          }

          if (eventType == 'widget_typing' || eventType == 'typing') {
            _typingController.add(decoded['is_typing'] ?? decoded['data']?['is_typing'] ?? false);
          }

          if (eventType == 'read') {
            for (var m in _messages) { if (m.sender == AdhookSender.visitor) m.isRead = true; }
            _messageController.add(currentMessages);
          }
          
          if (eventType == 'CALL_ENDED' || eventType == 'CALL_REJECTED' || eventType == 'INCOMING_CALL' || eventType == 'CALL_ACCEPTED' || eventType == 'CALL_HOLD') {
            _log("Voice Call event received: $eventType");
            _callEventController.add(Map<String, dynamic>.from(decoded));
          }

          if (eventType == 'error') {
            _errorController.add(decoded['error'] ?? "Unknown WebSocket error");
          }
        },
        onError: (error) {
          _log("WebSocket error: $error");
          _statusController.add(AdhookConnectionStatus.disconnected);
          _attemptReconnect();
        },
        onDone: () {
          _log("WebSocket closed");
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
        } else if (decoded is Map && decoded['data'] is List) {
          items = decoded['data'];
        } else if (decoded is Map && decoded['messages'] is List) {
          items = decoded['messages'];
        }

        // Unconditionally clear in-memory messages and SQLite local database for the session
        _messages.clear();
        if (!kIsWeb) await _localDb.clearAll();

        if (items.isNotEmpty) {
          for (var item in items) {
            if (item is Map) {
              final msg = AdhookMessage.fromJson(Map<String, dynamic>.from(item));
              _messages.add(msg);
              if (!kIsWeb) await _localDb.saveMessage(msg);
            }
          }
          _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
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

  /// Fetch all historical conversations for the current visitor
  Future<List<Map<String, dynamic>>> fetchConversationsList() async {
    if (_baseUrl == null) return [];
    try {
      final prefs = await SharedPreferences.getInstance();
      final visitorId = prefs.getString('adhook_visitor_id') ?? "visitor-${DateTime.now().millisecondsSinceEpoch}";
      final url = Uri.parse('$_baseUrl/api/widget/conversations/$visitorId?widget_key=$_widgetKey');
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['conversations'] is List) {
          return List<Map<String, dynamic>>.from(data['conversations']);
        }
      }
    } catch (e) {
      _log("Error fetching conversations list: $e");
    }
    return [];
  }

  /// Switch to a specific conversation history
  Future<void> openConversation(int conversationId) async {
    await _saveSession(conversationId.toString());
    _messages.clear();
    _messageController.add(currentMessages);
    await connect();
  }

  /// Clear current session from storage & memory
  Future<void> clearSession() async {
    _sessionId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('adhook_session_id');
    _messages.clear();
    if (!kIsWeb) await _localDb.clearAll();
    _messageController.add(currentMessages);
  }

  /// Start a brand new conversation
  Future<void> startNewConversation() async {
    await clearSession();
    await connect();
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

  void sendMessage(String text, {String? replyToId}) {
    if (!_isConnected || _channel == null) return;
    
    // Format JSON matching our backend WebSocket handler send_message action
    final messagePayload = {
      "action": "send_message",
      "content": text
    };
    if (replyToId != null) {
      messagePayload["reply_to_id"] = replyToId;
    }

    _channel!.sink.add(jsonEncode(messagePayload));
    sendTypingStatus(false);
  }

  void sendTypingStatus(bool isTyping) {
    if (!_isConnected || _channel == null) return;
    _channel!.sink.add(jsonEncode({
      "action": "typing",
      "is_typing": isTyping
    }));
  }

  void sendLocation(double lat, double lng) {
    if (!_isConnected || _channel == null) return;
    _channel!.sink.add(jsonEncode({
      "action": "location",
      "latitude": lat,
      "longitude": lng
    }));
  }

  void submitRating(int rating, String comment) {
    if (!_isConnected || _channel == null) return;
    _channel!.sink.add(jsonEncode({
      "action": "rating",
      "rating": rating,
      "comment": comment
    }));
  }

  Future<void> _uploadFile({String? path, List<int>? bytes, required String fileName}) async {
    if (_sessionId == null) {
      _errorController.add('Session not ready. Please try again.');
      return;
    }
    final request = http.MultipartRequest('POST', Uri.parse('$_baseUrl/api/widget/upload'));
    request.fields['session_id'] = _sessionId!;
    request.headers['Authorization'] = 'Bearer $_apiKey';
    if (bytes != null) {
      request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: fileName));
    } else if (path != null) {
      request.files.add(await http.MultipartFile.fromPath('file', path, filename: fileName));
    } else {
      return;
    }
    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode != 200) _handleApiError(response);
  }

  Future<void> pickFromGallery() async {
    final picker = ImagePicker();
    final xFile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (xFile != null) {
      await _uploadFile(path: xFile.path, fileName: xFile.name);
    }
  }

  Future<void> takePhoto() async {
    final picker = ImagePicker();
    final xFile = await picker.pickImage(source: ImageSource.camera, imageQuality: 85);
    if (xFile != null) {
      await _uploadFile(path: xFile.path, fileName: xFile.name);
    }
  }

  Future<void> pickDocument() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any, allowMultiple: false);
    if (result != null) {
      final file = result.files.single;
      await _uploadFile(path: file.path, bytes: file.bytes, fileName: file.name);
    }
  }

  Future<void> pickAndUploadFile() => pickDocument();

  /// Request a LiveKit WebRTC access token strictly for Voice Call only
  Future<Map<String, dynamic>> fetchLiveKitToken({
    String? roomName,
    String? identity,
    String? name,
    bool isAgent = false,
  }) async {
    if (_baseUrl == null) {
      throw Exception('AdhookChat is not initialized. Please call AdhookChat.init() first.');
    }

    final effectiveRoomName = (roomName != null && roomName.isNotEmpty)
        ? roomName
        : (_sessionId != null ? 'room_conv_$_sessionId' : 'room_voice_${DateTime.now().millisecondsSinceEpoch}');
    final effectiveIdentity = (identity != null && identity.isNotEmpty)
        ? identity
        : (_sessionId ?? _userPhone ?? 'user_${DateTime.now().millisecondsSinceEpoch}');
    final effectiveName = (name != null && name.isNotEmpty)
        ? name
        : (_userName ?? 'Peserta AdMedika');

    final url = Uri.parse('$_baseUrl/api/livekit/token');
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        if (_apiKey != null) 'Authorization': 'Bearer $_apiKey',
      },
      body: jsonEncode({
        'room_name': effectiveRoomName,
        'identity': effectiveIdentity,
        'name': effectiveName,
        'is_agent': isAgent,
        'call_type': 'voice',
      }),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('Failed to fetch LiveKit token: ${response.body}');
    }
  }

  /// Initiate a Voice Call: Generates token, triggers auto-recording, and alerts Dashboard Agents
  Future<Map<String, dynamic>> initiateVoiceCall({
    String? roomName,
    String? callerName,
  }) async {
    if (_baseUrl == null) {
      throw Exception('AdhookChat is not initialized. Please call AdhookChat.init() first.');
    }

    final effectiveCallerName = (callerName != null && callerName.isNotEmpty)
        ? callerName
        : (_userName ?? 'Peserta AdMedika');

    final url = Uri.parse('$_baseUrl/api/livekit/call/initiate');
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        if (_apiKey != null) 'Authorization': 'Bearer $_apiKey',
      },
      body: jsonEncode({
        'room_name': roomName,
        'caller_name': effectiveCallerName,
        'caller_phone': _userPhone ?? '',
        'session_id': _sessionId ?? '',
      }),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      try {
        final data = jsonDecode(response.body);
        if (data is Map && data['error'] != null) {
          throw Exception(data['error'].toString());
        }
      } catch (e) {
        if (e.toString().contains('Exception:')) rethrow;
      }
      throw Exception('Failed to initiate voice call: ${response.body}');
    }
  }

  /// End an active Voice Call
  Future<void> endVoiceCall({
    required String roomName,
    String? egressId,
  }) async {
    _callEventController.add({'event': 'CALL_ENDED', 'room_name': roomName});
    if (_baseUrl == null) return;

    final url = Uri.parse('$_baseUrl/api/livekit/call/end');
    await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        if (_apiKey != null) 'Authorization': 'Bearer $_apiKey',
      },
      body: jsonEncode({
        'room_name': roomName,
        'egress_id': egressId ?? '',
      }),
    );
  }

  Future<void> uploadFileFromPath(String path) async {
    await _uploadFile(path: path, fileName: path.split('/').last);
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
