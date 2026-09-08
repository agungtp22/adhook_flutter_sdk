import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/foundation.dart';
import 'src/models/message.dart';
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
  String? _visitorId;
  String? _userName;
  String? _userEmail;
  String? _userPhone;
  bool _debugMode = false;
  
  WebSocketChannel? _channel;
  bool _isConnected = false;
  bool _isConnecting = false;
  int _reconnectAttempts = 0;
  bool _hasConnectedEver = false;
  bool _conversationClosed = false;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Timer? _pollTimer;
  bool _isSyncing = false;

  final List<_OutboxItem> _outbox = [];
  Timer? _outboxTimer;
  bool _flushingOutbox = false;
  
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

  bool _isUploading = false;
  bool get isUploading => _isUploading;
  final _uploadProgressController = StreamController<bool>.broadcast();
  Stream<bool> get uploadStatusStream => _uploadProgressController.stream;
  bool _enableVoiceCall = false;
  bool get enableVoiceCall => _enableVoiceCall;
  final _configController = StreamController<bool>.broadcast();
  Stream<bool> get enableVoiceCallStream => _configController.stream;

  final _closedController = StreamController<bool>.broadcast();
  Stream<bool> get conversationClosedStream => _closedController.stream;

  String? _assignedAgentName;
  String? get assignedAgentName => _assignedAgentName;
  final _assignedAgentController = StreamController<String?>.broadcast();
  Stream<String?> get assignedAgentStream => _assignedAgentController.stream;

  bool get isConnected => _isConnected;
  bool get isConversationClosed => _conversationClosed;
  String? get visitorId => _visitorId;
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
    _visitorId = prefs.getString('adhook_visitor_id');
    _enableVoiceCall = prefs.getBool('adhook_enable_voice_call') ?? false;
    _configController.add(_enableVoiceCall);
  }

  String _getOrCreateVisitorId() {
    if (_visitorId != null && _visitorId!.isNotEmpty) return _visitorId!;
    final id = 'visitor-${DateTime.now().millisecondsSinceEpoch}';
    _visitorId = id;
    SharedPreferences.getInstance().then((p) => p.setString('adhook_visitor_id', id));
    return id;
  }

  Future<void> _persistVisitorId(String id) async {
    if (id.isEmpty || id == _visitorId) return;
    _visitorId = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('adhook_visitor_id', id);
    _log("Canonical visitor_id synced: $id");
  }

  void _applyConfig(dynamic cfg) {
    if (cfg is Map) {
      if (cfg.containsKey('enable_voice_call')) {
        _enableVoiceCall = cfg['enable_voice_call'] == true;
        SharedPreferences.getInstance().then((p) => p.setBool('adhook_enable_voice_call', _enableVoiceCall));
        _configController.add(_enableVoiceCall);
        _log("Applied widget config: enable_voice_call=$_enableVoiceCall");
      }
    }
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

    if (_conversationClosed) {
      _log("Conversation closed, connect() ignored. Call startNewConversation() instead.");
      return;
    }

    if (_isConnected && _channel != null) {
      _log("WebSocket already connected, skipping connect.");
      return;
    }

    if (_isConnecting) {
      _log("WebSocket connection already in progress, skipping duplicate connect.");
      return;
    }
    _isConnecting = true;

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
      _startPolling();

      // Restore & kirim ulang pesan yang sempat mengantre saat offline.
      await _restoreOutbox();
      if (_outbox.isNotEmpty) _flushOutbox();

      final wsUrl = '${_baseUrl!.replaceFirst('http', 'ws')}/ws/widget/$_sessionId';
      _log("Handshaking with URL: $wsUrl");

      // Close previous channel cleanly before opening new one
      try {
        _channel?.sink.close();
      } catch (_) {}

      final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _channel = channel;
      
      // Perform handshake
      channel.sink.add(jsonEncode({
        "type": "widget",
        "session_id": _sessionId,
        "widget_key": _widgetKey
      }));

      channel.stream.listen(
        (data) {
          final decoded = jsonDecode(data);
          _log("Received: $data");

          final eventType = decoded['event'] ?? decoded['type'];

          if (eventType == 'connected') {
            _isConnected = true;
            _isConnecting = false;
            _reconnectAttempts = 0;
            _hasConnectedEver = true;
            _statusController.add(AdhookConnectionStatus.connected);

            // Start keepalive ping every 25 seconds to prevent proxy/APIM idle disconnects
            _pingTimer?.cancel();
            _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
              if (_isConnected && _channel != null) {
                try {
                  _channel!.sink.add(jsonEncode({"action": "ping"}));
                } catch (_) {}
              }
            });

            _startPolling();

            // Koneksi pulih => kirim ulang pesan antrean (bila ada).
            _flushOutbox();
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
            final rawData = decoded['data'] is Map ? decoded['data'] : decoded;
            final agentName = (rawData['agent_name'] ?? decoded['agent_name'] ?? 'Support Agent').toString();
            _assignedAgentName = agentName;
            _assignedAgentController.add(agentName);

            final systemMsg = AdhookMessage(
              id: 'sys-${DateTime.now().millisecondsSinceEpoch}',
              content: 'Obrolan Anda telah dialihkan ke $agentName',
              sender: AdhookSender.system,
              createdAt: DateTime.now(),
              type: 'system'
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
            bool changed = false;
            for (var m in _messages) {
              if (m.sender == AdhookSender.visitor &&
                  m.deliveryStatus != AdhookDeliveryStatus.pending) {
                m.isRead = true;
                m.deliveryStatus = AdhookDeliveryStatus.read;
                changed = true;
              }
            }
            if (changed) _messageController.add(currentMessages);
          }
          
          if (eventType == 'CALL_ENDED' || eventType == 'CALL_REJECTED' || eventType == 'INCOMING_CALL' || eventType == 'CALL_ACCEPTED' || eventType == 'CALL_HOLD') {
            _log("Voice Call event received: $eventType");
            _callEventController.add(Map<String, dynamic>.from(decoded));
          }

          if (eventType == 'error') {
            _handleSessionError((decoded['error'] ?? "Unknown WebSocket error").toString());
          }
        },
        onError: (error) {
          _log("WebSocket error: $error");
          _onWsClosed();
        },
        onDone: () {
          _log("WebSocket closed");
          _onWsClosed();
        },
      );
    } catch (e) {
      _isConnected = false;
      _isConnecting = false;
      _pingTimer?.cancel();
      _statusController.add(AdhookConnectionStatus.disconnected);
      _errorController.add(e.toString());
      _attemptReconnect();
    }
  }

  void _onWsClosed() {
    _isConnected = false;
    _isConnecting = false;
    _pingTimer?.cancel();
    _statusController.add(AdhookConnectionStatus.disconnected);
    _attemptReconnect();
  }

  void _attemptReconnect() {
    if (_conversationClosed) return;
    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    if (_reconnectAttempts >= 12) {
      _log("Reconnect limit reached, giving up until manual retry.");
      _isConnected = false;
      _isConnecting = false;
      _statusController.add(AdhookConnectionStatus.disconnected);
      _errorController.add('Koneksi terputus. Periksa jaringan Anda lalu mulai ulang.');
      return;
    }
    // Self-heal: session kemungkinan sudah invalid/kedaluwarsa di server
    // (mis. dihapus/ditutup). Buat session baru daripada reconnect selamanya.
    if (_reconnectAttempts % 4 == 0 && !_hasConnectedEver) {
      _log("Reconnect repeatedly failing without ever connecting; resetting stale session...");
      _recoverFromInvalidSession();
      return;
    }
    final delay = Duration(seconds: (_reconnectAttempts * 2).clamp(2, 10));
    _log("Scheduling reconnect attempt $_reconnectAttempts in ${delay.inSeconds}s");
    _reconnectTimer = Timer(delay, () {
      if (!_conversationClosed) connect();
    });
  }

  void _handleSessionError(String text) {
    _errorController.add(text);
    final t = text.toLowerCase();
    if (t.contains('conversation_closed')) {
      _markConversationClosed();
      return;
    }
    if (t.contains('session') || t.contains('expired') || t.contains('invalid')) {
      _recoverFromInvalidSession();
    }
  }

  void _markConversationClosed() {
    if (_conversationClosed) return;
    _log("Conversation closed, entering read-only state");
    _conversationClosed = true;
    _isConnected = false;
    _isConnecting = false;
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _pollTimer?.cancel();
    _clearOutbox(); // pesan pending tidak akan dikirim ke chat baru
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _statusController.add(AdhookConnectionStatus.disconnected);
    _closedController.add(true);
  }

  void _clearConversationClosed() {
    if (!_conversationClosed) return;
    _conversationClosed = false;
    _closedController.add(false);
  }

  Future<void> _recoverFromInvalidSession() async {
    _log("Recovering from invalid/stale session...");
    _reconnectTimer?.cancel();
    _pollTimer?.cancel();
    _pingTimer?.cancel();
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _isConnected = false;
    _isConnecting = false;
    _clearConversationClosed();
    await _clearOutbox();

    final prefs = await SharedPreferences.getInstance();
    _sessionId = null;
    await prefs.remove('adhook_session_id');
    _messages.clear();
    if (!kIsWeb) await _localDb.clearAll();
    _messageController.add(currentMessages);

    try {
      await _createNewSession();
    } catch (e) {
      _log("Failed to create fresh session: $e");
      _errorController.add('Gagal membuat sesi baru: $e');
      // Kemungkinan jaringan bermasalah; coba lagi nanti.
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(const Duration(seconds: 10), () {
        if (!_conversationClosed) connect();
      });
      return;
    }
    _reconnectAttempts = 0;
    _hasConnectedEver = false;
    await connect();
  }

  void disconnect() {
    _isConnected = false;
    _isConnecting = false;
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _pollTimer?.cancel();
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _statusController.add(AdhookConnectionStatus.disconnected);
  }

  void startPolling() => _startPolling();
  void stopPolling() => _pollTimer?.cancel();

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _syncLatestMessages();
    });
  }

  /// Sync messages manually or upon app lifecycle resume
  Future<void> syncMessages() async {
    await _syncLatestMessages();
  }

  Future<void> _syncLatestMessages() async {
    if (_sessionId == null || _baseUrl == null || _isSyncing) return;
    _isSyncing = true;
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/widget/messages/$_sessionId'),
        headers: {'Authorization': 'Bearer $_apiKey'},
      );

      if (response.statusCode == 200) {
        final dynamic decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['config'] != null) {
          _applyConfig(decoded['config']);
        }
        List<dynamic> items = [];
        if (decoded is List) {
          items = decoded;
        } else if (decoded is Map && decoded['data'] is List) {
          items = decoded['data'];
        } else if (decoded is Map && decoded['messages'] is List) {
          items = decoded['messages'];
        }

        bool hasNew = false;
        for (var item in items) {
          if (item is Map) {
            final msg = AdhookMessage.fromJson(Map<String, dynamic>.from(item));
            if (msg.id.isNotEmpty && !_messages.any((m) => m.id == msg.id)) {
              _messages.add(msg);
              if (!kIsWeb) await _localDb.saveMessage(msg);
              hasNew = true;
            }
          }
        }

        if (hasNew) {
          _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          _messageController.add(currentMessages);
        }
      }
    } catch (_) {
      // Silent error during periodic background poll
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> _fetchHistory() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/widget/messages/$_sessionId'),
        headers: {'Authorization': 'Bearer $_apiKey'},
      );

      if (response.statusCode == 200) {
        final dynamic decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['config'] != null) {
          _applyConfig(decoded['config']);
        }
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
          "visitor_id": _getOrCreateVisitorId(),
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
        final vid = data['visitor_id'];
        if (vid is String && vid.isNotEmpty) {
          await _persistVisitorId(vid);
        }
        if (data['config'] != null) {
          _applyConfig(data['config']);
        }
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
      final visitorId = _getOrCreateVisitorId();
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

  /// Fetch messages of an arbitrary (possibly past/closed) conversation.
  /// [sessionId] hanya diperlukan untuk conversation yang masih aktif.
  Future<List<AdhookMessage>> fetchConversationMessages(
    int conversationId, {
    String? sessionId,
  }) async {
    if (_baseUrl == null) return [];
    try {
      final sid = (sessionId != null && sessionId.isNotEmpty) ? sessionId : 'view';
      final response = await http.get(
        Uri.parse('$_baseUrl/api/widget/messages/$sid?conv_id=$conversationId'),
        headers: {if (_apiKey != null) 'Authorization': 'Bearer $_apiKey'},
      );
      if (response.statusCode == 200) {
        final dynamic decoded = jsonDecode(response.body);
        List<dynamic> items = [];
        if (decoded is List) {
          items = decoded;
        } else if (decoded is Map && decoded['messages'] is List) {
          items = decoded['messages'];
        }
        return items
            .whereType<Map>()
            .map((item) => AdhookMessage.fromJson(Map<String, dynamic>.from(item)))
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      }
    } catch (e) {
      _log("Error fetching conversation messages: $e");
    }
    return [];
  }

  /// Switch to a specific conversation.
  /// - Conversation yang masih [isClosed]=false & punya [sessionId] di-resume
  ///   (reconnect ke session tersebut).
  /// - Conversation yang sudah ditutup ditampilkan read-only (riwayat saja).
  Future<void> openConversation({
    required int conversationId,
    String? sessionId,
    bool isClosed = false,
  }) async {
    _log("openConversation: conv=$conversationId session=$sessionId closed=$isClosed");
    if (isClosed || sessionId == null || sessionId.isEmpty) {
      await _loadReadOnlyConversation(conversationId, sessionId);
      return;
    }

    // Resume conversation aktif: pindah session & refresh history via WS+HTTP.
    _clearConversationClosed();
    await _saveSession(sessionId);
    disconnect();
    _reconnectAttempts = 0;
    _hasConnectedEver = false;
    _messages.clear();
    if (!kIsWeb) await _localDb.clearAll();
    _messageController.add(currentMessages);
    await connect();
  }

  Future<void> _loadReadOnlyConversation(int conversationId, String? sessionId) async {
    _pollTimer?.cancel();
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _isConnected = false;
    _isConnecting = false;
    _statusController.add(AdhookConnectionStatus.disconnected);

    final msgs = await fetchConversationMessages(conversationId, sessionId: sessionId);
    _messages.clear();
    if (!kIsWeb) await _localDb.clearAll();
    if (msgs.isNotEmpty) _messages.addAll(msgs);

    // Tutup view ini sebagai conversation yang sudah selesai (read-only).
    _markConversationClosed();
    _messageController.add(currentMessages);
  }

  /// Clear current session from storage & memory
  Future<void> clearSession() async {
    _sessionId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('adhook_session_id');
    await _clearOutbox();
    _messages.clear();
    if (!kIsWeb) await _localDb.clearAll();
    _messageController.add(currentMessages);
  }

  /// Start a brand new conversation
  Future<void> startNewConversation() async {
    _clearConversationClosed();
    disconnect();
    await clearSession();
    await connect();
  }

  String _extractErrorText(http.Response response) {
    try {
      final data = jsonDecode(response.body);
      if (data is Map && data['error'] != null) return data['error'].toString();
    } catch (_) {}
    return "Request failed with status ${response.statusCode}";
  }

  void _handleApiError(http.Response response) {
    _errorController.add(_extractErrorText(response));
  }

  void sendMessage(String text, {String? replyToId}) {
    if (text.trim().isEmpty) return;

    if (_conversationClosed) {
      _errorController.add('Percakapan telah diakhiri. Silakan mulai chat baru.');
      return;
    }

    if (_sessionId == null) {
      _errorController.add('Sesi belum siap. Coba lagi.');
      return;
    }

    // WS tidak terhubung (mis. app baru balik dari background / reconnect)
    // => masukkan ke antrean outbox, nanti dikirim ulang otomatis.
    if (!_isConnected || _channel == null) {
      _enqueueOutgoingMessage(text, replyToId: replyToId);
      _flushOutbox();
      return;
    }

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

  // ===================== Outbox (antrean pesan offline) =====================

  /// Tambahkan pesan ke antrean lokal & tampilkan sebagai 'pending'.
  void _enqueueOutgoingMessage(String text, {String? replyToId}) {
    final localId = 'out-${DateTime.now().microsecondsSinceEpoch}';
    _outbox.add(_OutboxItem(localId: localId, text: text, replyToId: replyToId, createdAt: DateTime.now()));
    _persistOutbox();

    if (!_messages.any((m) => m.id == localId)) {
      final msg = AdhookMessage(
        id: localId,
        content: text,
        sender: AdhookSender.visitor,
        createdAt: DateTime.now(),
        type: 'TEXT',
        isRead: false,
        deliveryStatus: AdhookDeliveryStatus.pending,
        replyToId: replyToId,
      );
      _messages.add(msg);
      _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _messageController.add(currentMessages);
      if (!kIsWeb) _localDb.saveMessage(msg);
    }
  }

  Future<void> _persistOutbox() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('adhook_outbox', jsonEncode(_outbox.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  /// Restore antrean tersimpan (mis. app ditutup saat masih offline).
  Future<void> _restoreOutbox() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('adhook_outbox');
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final items = decoded
          .whereType<Map>()
          .map((m) => _OutboxItem.fromJson(Map<String, dynamic>.from(m)))
          .toList();
      for (final item in items) {
        if (_outbox.any((e) => e.localId == item.localId)) continue;
        _outbox.add(item);
        if (!_messages.any((m) => m.id == item.localId)) {
          _messages.add(AdhookMessage(
            id: item.localId,
            content: item.text,
            sender: AdhookSender.visitor,
            createdAt: item.createdAt,
            type: 'TEXT',
            isRead: false,
            deliveryStatus: AdhookDeliveryStatus.pending,
            replyToId: item.replyToId,
          ));
        }
      }
      if (items.isNotEmpty) {
        _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        _messageController.add(currentMessages);
      }
    } catch (_) {}
  }

  Future<void> _clearOutbox() async {
    _outboxTimer?.cancel();
    _outboxTimer = null;
    _outbox.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('adhook_outbox');
    } catch (_) {}
  }

  void _scheduleOutboxFlush() {
    if (_conversationClosed || _outbox.isEmpty) return;
    _outboxTimer?.cancel();
    _outboxTimer = Timer.periodic(const Duration(seconds: 4), (_) => _flushOutbox());
  }

  /// Kirim ulang seluruh isi antrean secara berurutan (HTTP /api/widget/message).
  Future<void> _flushOutbox() async {
    if (_flushingOutbox || _outbox.isEmpty || _conversationClosed) return;
    if (_baseUrl == null || _sessionId == null) return;
    _flushingOutbox = true;
    try {
      final items = List<_OutboxItem>.from(_outbox);
      for (final item in items) {
        if (_conversationClosed) break;
        if (!_outbox.any((e) => e.localId == item.localId)) continue;

        final result = await _httpSendOutboxItem(item);
        if (result == null) break; // jaringan bermasalah, retry nanti

        _outbox.removeWhere((e) => e.localId == item.localId);
        await _persistOutbox();

        if (result.permanentError) {
          _removePendingMessage(item.localId);
          _handlePermanentSendError(result.errorText ?? '');
          break;
        }
        _promotePendingToSent(item.localId, result.serverId ?? '');
      }
    } finally {
      _flushingOutbox = false;
      if (_outbox.isEmpty) {
        _outboxTimer?.cancel();
        _outboxTimer = null;
      } else if (!_conversationClosed) {
        _scheduleOutboxFlush();
      }
    }
  }

  Future<_SendOutboxResult?> _httpSendOutboxItem(_OutboxItem item) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/widget/message'),
        headers: {
          'Content-Type': 'application/json',
          if (_apiKey != null) 'Authorization': 'Bearer $_apiKey',
        },
        body: jsonEncode({
          'session_id': _sessionId,
          'message': item.text,
          if (item.replyToId != null) 'reply_to_id': item.replyToId,
        }),
      );

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final mid = decoded is Map ? decoded['message_id'] : null;
        return _SendOutboxResult(serverId: mid == null ? null : '$mid');
      }
      if (response.statusCode >= 500) return null; // server error → coba lagi
      return _SendOutboxResult(permanentError: true, errorText: _extractErrorText(response));
    } catch (_) {
      return null;
    }
  }

  void _handlePermanentSendError(String errText) {
    _log("Outbox send permanently rejected: $errText");
    final t = errText.toLowerCase();
    if (t.contains('conversation_closed')) {
      _markConversationClosed();
    } else if (t.contains('session') || t.contains('invalid') || t.contains('expired')) {
      _recoverFromInvalidSession();
    } else {
      _errorController.add(errText);
    }
  }

  void _removePendingMessage(String localId) {
    _messages.removeWhere((m) => m.id == localId);
    _messageController.add(currentMessages);
    if (!kIsWeb) _localDb.deleteMessage(localId);
  }

  void _promotePendingToSent(String localId, String serverId) {
    final idx = _messages.indexWhere((m) => m.id == localId);
    if (idx < 0) return;
    final old = _messages[idx];
    _messages[idx] = AdhookMessage(
      id: serverId.isNotEmpty ? serverId : old.id,
      content: old.content,
      sender: old.sender,
      createdAt: old.createdAt,
      type: old.type,
      senderName: old.senderName,
      conversationId: old.conversationId,
      contactId: old.contactId,
      mediaUrl: old.mediaUrl,
      mimeType: old.mimeType,
      isRead: false,
      deliveryStatus: AdhookDeliveryStatus.sent,
      replyToId: old.replyToId,
      replyToContent: old.replyToContent,
      replyToSender: old.replyToSender,
    );
    _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _messageController.add(currentMessages);
    if (!kIsWeb) {
      if (serverId.isNotEmpty) _localDb.deleteMessage(localId);
      _localDb.saveMessage(_messages[idx]);
    }
  }

  void sendTypingStatus(bool isTyping) {
    if (_conversationClosed || !_isConnected || _channel == null) return;
    _channel!.sink.add(jsonEncode({
      "action": "typing",
      "is_typing": isTyping
    }));
  }

  void sendLocation(double lat, double lng) {
    if (_conversationClosed) {
      _errorController.add('Percakapan telah diakhiri. Silakan mulai chat baru.');
      return;
    }
    if (!_isConnected || _channel == null) return;
    _channel!.sink.add(jsonEncode({
      "action": "location",
      "latitude": lat,
      "longitude": lng
    }));
  }

  void submitRating(int rating, String comment) {
    if (_conversationClosed) return;
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

    _isUploading = true;
    _uploadProgressController.add(true);

    try {
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
      if (response.statusCode == 200) {
        try {
          final resJson = jsonDecode(response.body);
          if (resJson is Map<String, dynamic>) {
            final rawData = resJson['data'] ?? resJson['message'];
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
          }
        } catch (_) {}
      } else {
        _handleApiError(response);
      }
    } catch (e) {
      _errorController.add("Upload failed: $e");
    } finally {
      _isUploading = false;
      _uploadProgressController.add(false);
    }
  }

  Future<void> pickFromGallery() async {
    final picker = ImagePicker();
    try {
      final xFile = await picker.pickMedia();
      if (xFile != null) {
        await _uploadFile(path: xFile.path, fileName: xFile.name);
        return;
      }
    } catch (_) {
      // Fallback if pickMedia is not supported on older platforms
      final xFile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (xFile != null) {
        await _uploadFile(path: xFile.path, fileName: xFile.name);
      }
    }
  }

  Future<void> pickVideo() async {
    final picker = ImagePicker();
    final xFile = await picker.pickVideo(source: ImageSource.gallery);
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
    _outboxTimer?.cancel();
    _messageController.close();
    _typingController.close();
    _statusController.close();
    _errorController.close();
    _closedController.close();
  }
}

/// Item pesan yang mengantre (belum sampai server) saat koneksi terputus.
class _OutboxItem {
  final String localId;
  final String text;
  final String? replyToId;
  final DateTime createdAt;

  _OutboxItem({
    required this.localId,
    required this.text,
    this.replyToId,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': localId,
        'text': text,
        'reply_to_id': replyToId,
        'created_at': createdAt.toIso8601String(),
      };

  factory _OutboxItem.fromJson(Map<String, dynamic> json) => _OutboxItem(
        localId: (json['id'] ?? '').toString(),
        text: (json['text'] ?? '').toString(),
        replyToId: json['reply_to_id']?.toString(),
        createdAt: AdhookMessage.parseCreatedAt(json['created_at']),
      );
}

class _SendOutboxResult {
  final bool permanentError;
  final String? serverId;
  final String? errorText;

  _SendOutboxResult({this.permanentError = false, this.serverId, this.errorText});
}
