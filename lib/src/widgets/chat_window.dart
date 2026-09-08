import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'package:flutter_link_previewer/flutter_link_previewer.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' show PreviewData;
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart';
import 'package:geolocator/geolocator.dart';
import 'package:photo_view/photo_view.dart';
import 'package:livekit_client/livekit_client.dart';
import '../../adhook_flutter_sdk.dart';

class AdhookChatWindow extends StatefulWidget {
  final String title;
  final Widget? leading;
  final AdhookChatStyle style;

  const AdhookChatWindow({
    super.key,
    this.title = 'Customer Support',
    this.leading,
    this.style = const AdhookChatStyle(),
  });

  @override
  State<AdhookChatWindow> createState() => _AdhookChatWindowState();
}

class _AdhookChatWindowState extends State<AdhookChatWindow> with TickerProviderStateMixin, WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  
  final ScrollController _scrollController = ScrollController();
  final AdhookChat _adhook = AdhookChat();
  final AudioRecorder _audioRecorder = AudioRecorder();
  
  bool _showForm = false;
  bool _isRecording = false;
  double _amplitude = 0.0;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  Timer? _typingTimer;

  // Reply State
  AdhookMessage? _replyingTo;
  
  // Link Preview Cache
  final Map<String, PreviewData> _previewDataCache = {};

  bool _hasShownRating = false;
  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
    _showForm = !_adhook.hasUserInfo;
    if (!_showForm) {
      _adhook.connect();
    }
    _adhook.startPolling();
    
    // Listen to errors from SDK
    _adhook.errorStream.listen((error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error: $error", style: const TextStyle(fontWeight: FontWeight.w600)),
            backgroundColor: const Color(0xFFEF4444),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    });

    _adhook.conversationClosedStream.listen((_) {
      if (mounted) setState(() {});
    });

    _adhook.messageHistory.listen((messages) {
       if (_adhook.isConversationClosed) return;
       if (messages.isNotEmpty && 
          (messages.last.type == 'system' || messages.last.sender == AdhookSender.system) && 
          (messages.last.content == 'conversation_closed' || messages.last.content.contains('conversation_closed'))) {
         if (!_hasShownRating) {
           _hasShownRating = true;
           _showRatingDialog();
         }
       }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _adhook.syncMessages();
      if (!_adhook.isConnected) {
        _adhook.connect();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_onScroll);
    _adhook.stopPolling();
    _typingTimer?.cancel();
    _amplitudeSubscription?.cancel();
    _controller.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.offset;
    final isFarFromBottom = (maxScroll - currentScroll) > 160;
    if (isFarFromBottom != _showScrollToBottom) {
      setState(() => _showScrollToBottom = isFarFromBottom);
    }
  }

  void _showRatingDialog() {
    int selectedRating = 5;
    final commentController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: widget.style.brightness == Brightness.dark ? const Color(0xFF1E1E1E) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: widget.style.primaryColor.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.rate_review_outlined, color: widget.style.primaryColor, size: 28),
              ),
              const SizedBox(height: 16),
              Text(
                "Rate Our Service", 
                textAlign: TextAlign.center, 
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                  color: widget.style.brightness == Brightness.dark ? Colors.white : Colors.black
                )
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "How was your experience with our agent?", 
                style: TextStyle(fontSize: 14, color: widget.style.brightness == Brightness.dark ? Colors.white70 : Colors.black87), 
                textAlign: TextAlign.center
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (index) => IconButton(
                  icon: Icon(index < selectedRating ? Icons.star_rounded : Icons.star_outline_rounded, color: Colors.amber, size: 36),
                  onPressed: () => setState(() => selectedRating = index + 1),
                )),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: commentController,
                maxLines: 2,
                style: TextStyle(color: widget.style.brightness == Brightness.dark ? Colors.white : Colors.black),
                decoration: InputDecoration(
                  hintText: "Your feedback (optional)", 
                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                  filled: true,
                  fillColor: widget.style.brightness == Brightness.dark ? Colors.white10 : Colors.grey[50],
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await _adhook.startNewConversation();
                if (context.mounted) Navigator.pop(context);
              }, 
              child: const Text("Skip", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600))
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: widget.style.primaryColor, 
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              onPressed: () async {
                _adhook.submitRating(selectedRating, commentController.text.trim());
                await _adhook.startNewConversation();
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text("Thank you for your feedback!"),
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    )
                  );
                }
              },
              child: const Text("Submit", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    
    final position = await Geolocator.getCurrentPosition();
    _adhook.sendLocation(position.latitude, position.longitude);
  }

  void _showAttachmentSheet(AdhookChatStyle style) {
    final isDark = style.brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.grey[350],
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Share Content',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF1A1A2E),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Choose how you\'d like to share',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : Colors.grey[500],
                  ),
                ),
                const SizedBox(height: 20),
                _attachmentRow(
                  icon: Icons.photo_library_rounded,
                  gradient: [const Color(0xFF6366F1), const Color(0xFF8B5CF6)],
                  emoji: '🖼️',
                  title: 'Photo & Video',
                  subtitle: 'Choose from your gallery',
                  onTap: () { Navigator.pop(ctx); _adhook.pickFromGallery(); },
                  isDark: isDark,
                ),
                const SizedBox(height: 10),
                _attachmentRow(
                  icon: Icons.camera_alt_rounded,
                  gradient: [const Color(0xFF10B981), const Color(0xFF34D399)],
                  emoji: '📸',
                  title: 'Camera',
                  subtitle: 'Take a photo now',
                  onTap: () { Navigator.pop(ctx); _adhook.takePhoto(); },
                  isDark: isDark,
                ),
                const SizedBox(height: 10),
                _attachmentRow(
                  icon: Icons.description_rounded,
                  gradient: [const Color(0xFFF59E0B), const Color(0xFFF97316)],
                  emoji: '📄',
                  title: 'Document',
                  subtitle: 'Send any file type',
                  onTap: () { Navigator.pop(ctx); _adhook.pickDocument(); },
                  isDark: isDark,
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _attachmentRow({
    required IconData icon,
    required List<Color> gradient,
    required String emoji,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: 0.04) : Colors.grey[50],
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.grey[200]!,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: gradient),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: Text(emoji, style: const TextStyle(fontSize: 22)),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : const Color(0xFF1A1A2E),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white38 : Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.grey[200],
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: isDark ? Colors.white54 : Colors.grey[500],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final directory = await getTemporaryDirectory();
        final path = '${directory.path}/adhook_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
        await _audioRecorder.start(const RecordConfig(), path: path);
        _amplitudeSubscription = _audioRecorder.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((amp) {
          setState(() => _amplitude = amp.current);
        });
        setState(() => _isRecording = true);
      }
    } catch (e) {
      debugPrint("Error starting record: $e");
    }
  }

  Future<void> _stopRecording() async {
    try {
      _amplitudeSubscription?.cancel();
      final path = await _audioRecorder.stop();
      setState(() { _isRecording = false; _amplitude = 0.0; });
      if (path != null) await _adhook.uploadFileFromPath(path);
    } catch (e) {
      debugPrint("Error stopping record: $e");
    }
  }

  void _onTextChanged(String text) {
    setState(() {}); // Re-build to show/hide send button dynamically
    if (text.isEmpty) { _adhook.sendTypingStatus(false); return; }
    if (_typingTimer == null || !_typingTimer!.isActive) _adhook.sendTypingStatus(true);
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 3), () => _adhook.sendTypingStatus(false));
  }

  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        if (force || !_showScrollToBottom) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent, 
            duration: const Duration(milliseconds: 300), 
            curve: Curves.easeOutCubic
          );
        }
      }
    });
  }

  String _formatTime(DateTime date) => DateFormat('HH:mm').format(date);

  void _onImageTap(String url) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => FullImageViewer(url: url)));
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    return Theme(
      data: Theme.of(context).copyWith(
        brightness: style.brightness,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: style.primaryColor,
          brightness: style.brightness,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          filled: false,
        ),
        textTheme: Theme.of(context).textTheme.apply(
          fontFamily: style.fontFamily, 
          bodyColor: style.brightness == Brightness.dark ? Colors.white : Colors.black87
        ),
      ),
      child: Scaffold(
        backgroundColor: style.backgroundColor,
        appBar: style.showAppBar 
          ? AppBar(
              elevation: 2,
              shadowColor: Colors.black26,
              leading: widget.leading != null ? Padding(padding: const EdgeInsets.only(left: 12), child: Center(child: widget.leading)) : null,
              title: StreamBuilder<String?>(
                stream: _adhook.assignedAgentStream,
                initialData: _adhook.assignedAgentName,
                builder: (context, agentSnap) {
                  final activeAgent = agentSnap.data ?? _adhook.assignedAgentName;
                  final displayTitle = (activeAgent != null && activeAgent.isNotEmpty)
                      ? activeAgent
                      : widget.title;
                  return Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white38, width: 1.5),
                        ),
                        child: Icon(
                          activeAgent != null ? Icons.person_rounded : Icons.support_agent_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayTitle,
                              style: style.applyFont(
                                style.appBarTitleStyle ??
                                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            StreamBuilder<bool>(
                              stream: _adhook.agentTypingStatus,
                              initialData: false,
                              builder: (context, snapshot) {
                                if (snapshot.data == true) {
                                  return const Text(
                                    "Agent is typing...",
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.white70,
                                      fontStyle: FontStyle.italic,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  );
                                }
                                return Row(
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      activeAgent != null ? "Online" : "Always Active",
                                      style: const TextStyle(fontSize: 10, color: Colors.white70, fontWeight: FontWeight.w500),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.history_rounded, color: Colors.white),
                  tooltip: 'Riwayat Chat',
                  onPressed: () => _showHistoryBottomSheet(context),
                ),
                StreamBuilder<bool>(
                  stream: _adhook.enableVoiceCallStream,
                  initialData: _adhook.enableVoiceCall,
                  builder: (context, snapshot) {
                    final isEnabled = style.enableVoiceCall ?? snapshot.data ?? false;
                    if (!isEnabled) return const SizedBox.shrink();
                    return IconButton(
                      icon: const Icon(Icons.phone_rounded, color: Colors.white),
                      tooltip: 'Panggilan Suara CS',
                      onPressed: () => _startVoiceCall(context),
                    );
                  },
                ),
                const SizedBox(width: 4),
              ],
              backgroundColor: style.primaryColor,
              foregroundColor: style.appBarTitleStyle?.color ?? Colors.white,
            )
          : null,
        body: _showForm 
            ? _buildForm(style)
            : Column(
                children: [
                  _buildConnectionStatus(style),
                  Expanded(
                    child: Stack(
                      children: [
                        StreamBuilder<List<AdhookMessage>>(
                          stream: _adhook.messageHistory,
                          initialData: _adhook.currentMessages,
                          builder: (context, snapshot) {
                            final messages = snapshot.data ?? [];
                            _scrollToBottom();
                            return ListView.builder(
                              controller: _scrollController,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                              itemCount: messages.length,
                              itemBuilder: (context, index) {
                                final msg = messages[index];
                                // Render system transition notices centered without bubble (Biznet GIO style)
                                if (msg.isSystem) {
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 24),
                                    child: Center(
                                      child: Text(
                                        msg.content,
                                        textAlign: TextAlign.center,
                                        style: style.applyFont(
                                          TextStyle(
                                            fontSize: 12.5,
                                            color: style.brightness == Brightness.dark ? Colors.white60 : const Color(0xFF757575),
                                            fontWeight: FontWeight.w500,
                                            height: 1.4,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }

                                final isMe = msg.sender == AdhookSender.visitor;
                                final typeUpper = msg.type.toUpperCase();
                                final trimmedContent = msg.content.trim();
                                final isInteractive = typeUpper == 'BUTTON' ||
                                    typeUpper == 'LIST' ||
                                    typeUpper == 'MENU' ||
                                    (trimmedContent.startsWith('{') &&
                                        (trimmedContent.contains('"buttons"') ||
                                            trimmedContent.contains('"rows"') ||
                                            trimmedContent.contains('"sections"') ||
                                            trimmedContent.contains('"items"')));
                                return GestureDetector(
                                  onLongPress: () => setState(() => _replyingTo = msg),
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 14),
                                    child: Column(
                                      crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                      children: [
                                        if (!isMe)
                                          Padding(
                                            padding: const EdgeInsets.only(left: 6, bottom: 4), 
                                            child: Text(
                                              msg.senderName ?? _adhook.assignedAgentName ?? 'AdMedika Support', 
                                              style: style.applyFont(const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey))
                                            )
                                          ),
                                        Align(
                                          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                                          child: Container(
                                            constraints: BoxConstraints(
                                              minWidth: isInteractive ? (MediaQuery.of(context).size.width * 0.72) : 0,
                                              maxWidth: MediaQuery.of(context).size.width * 0.82,
                                            ),
                                            padding: style.bubblePadding,
                                            decoration: BoxDecoration(
                                              gradient: isMe 
                                                  ? LinearGradient(
                                                      colors: [style.visitorBubbleColor, style.visitorBubbleColor.withValues(alpha: 0.85)],
                                                      begin: Alignment.topLeft,
                                                      end: Alignment.bottomRight,
                                                    )
                                                  : null,
                                              color: isMe ? null : style.agentBubbleColor,
                                              borderRadius: BorderRadius.only(
                                                topLeft: const Radius.circular(16),
                                                topRight: const Radius.circular(16),
                                                bottomLeft: isMe ? const Radius.circular(16) : const Radius.circular(2),
                                                bottomRight: isMe ? const Radius.circular(2) : const Radius.circular(16),
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black.withValues(alpha: style.brightness == Brightness.dark ? 0.2 : 0.04), 
                                                  blurRadius: 6, 
                                                  offset: const Offset(0, 3)
                                                )
                                              ]
                                            ),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                if (msg.replyToContent != null) _buildReplyQuote(msg, isMe, style),
                                                _buildMessageBody(msg, isMe, style),
                                                const SizedBox(height: 6),
                                                Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  mainAxisAlignment: MainAxisAlignment.end,
                                                  children: [
                                                    Text(_formatTime(msg.createdAt), style: style.applyFont(TextStyle(fontSize: 9, color: isMe ? Colors.white70 : Colors.grey))),
                                                    if (isMe) ...[
                                                      const SizedBox(width: 4),
                                                      _buildDeliveryIcon(msg),
                                                    ],
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                        if (_showScrollToBottom)
                          Positioned(
                            right: 16,
                            bottom: 12,
                            child: GestureDetector(
                              onTap: () {
                                if (_scrollController.hasClients) {
                                  _scrollController.animateTo(
                                    _scrollController.position.maxScrollExtent,
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeOutCubic,
                                  );
                                }
                              },
                              child: Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: style.brightness == Brightness.dark ? const Color(0xFF2A2A2A) : Colors.white,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.15),
                                      blurRadius: 8,
                                      offset: const Offset(0, 3),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: style.brightness == Brightness.dark ? Colors.white70 : const Color(0xFF555555),
                                  size: 24,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  _buildUploadProgressIndicator(style),
                  _buildInputArea(style),
                ],
              ),
      ),
    );
  }

  Widget _buildReplyQuote(AdhookMessage msg, bool isMe, AdhookChatStyle style) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isMe ? Colors.black12 : (style.brightness == Brightness.dark ? Colors.white10 : Colors.black.withValues(alpha: 0.05)),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: style.primaryColor, width: 3.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(msg.replyToSender ?? "Original Message", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: style.primaryColor)),
          const SizedBox(height: 2),
          Text(msg.replyToContent!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: isMe ? Colors.white70 : Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildDeliveryIcon(AdhookMessage msg) {
    // Pending = masih di antrean (belum sampai server)
    if (msg.deliveryStatus == AdhookDeliveryStatus.pending) {
      return const Icon(Icons.schedule, size: 12, color: Colors.white60);
    }
    // Read = sudah dibaca agent => centang ganda biru
    if (msg.isRead || msg.deliveryStatus == AdhookDeliveryStatus.read) {
      return const Icon(Icons.done_all, size: 13, color: Colors.blueAccent);
    }
    // Sent = sampai server => centang tunggal
    return const Icon(Icons.done, size: 13, color: Colors.white60);
  }

  Widget _buildMessageBody(AdhookMessage msg, bool isMe, AdhookChatStyle style) {
    if (msg.type.toLowerCase() == 'system') return Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 8.0), child: Text(msg.content, style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Colors.grey))));

    final typeUpper = msg.type.toUpperCase();
    final trimmedContent = msg.content.trim();
    final isInteractive = typeUpper == 'BUTTON' ||
        typeUpper == 'LIST' ||
        typeUpper == 'MENU' ||
        (trimmedContent.startsWith('{') &&
            (trimmedContent.contains('"buttons"') ||
                trimmedContent.contains('"rows"') ||
                trimmedContent.contains('"sections"') ||
                trimmedContent.contains('"items"')));

    if (isInteractive) return _buildButtonContent(msg, isMe, style);

    final typeLower = msg.type.toLowerCase();
    final mediaUrl = msg.mediaUrl ?? '';
    final lowerContent = msg.content.toLowerCase();
    final lowerMediaUrl = mediaUrl.toLowerCase();

    // Check if message is Image
    final isImage = typeLower == 'image' ||
        (mediaUrl.isNotEmpty && (lowerMediaUrl.contains(RegExp(r'\.(jpg|jpeg|png|gif|webp)')) || typeLower == 'image')) ||
        lowerContent.contains(RegExp(r'\.(jpg|jpeg|png|gif|webp)'));

    if (isImage) {
      final imgPath = mediaUrl.isNotEmpty ? mediaUrl : msg.content;
      final fullUrl = imgPath.startsWith('http') ? imgPath : '${_adhook.baseUrl}$imgPath';
      return _buildImageContent(msg, fullUrl, isMe, style);
    }

    final isVideo = typeLower == 'video' ||
        lowerContent.contains(RegExp(r'\.(mp4|mov|avi|mkv|webm|3gp|m4v)')) ||
        lowerMediaUrl.contains(RegExp(r'\.(mp4|mov|avi|mkv|webm|3gp|m4v)'));

    if (isVideo) {
      final videoPath = mediaUrl.isNotEmpty ? mediaUrl : msg.content;
      final videoUrl = videoPath.startsWith('http') ? videoPath : '${_adhook.baseUrl}$videoPath';
      return _buildVideoCard(videoUrl, isMe, style);
    }

    if (typeLower == 'location' || lowerContent.startsWith('lat:')) return _buildLocationBubble(msg.content, isMe, style);

    final isAudio = typeLower == 'audio' ||
        lowerContent.contains(RegExp(r'\.(m4a|mp3|wav|aac)')) ||
        lowerMediaUrl.contains(RegExp(r'\.(m4a|mp3|wav|aac)'));

    if (isAudio) {
      final audioPath = mediaUrl.isNotEmpty ? mediaUrl : msg.content;
      final audioUrl = audioPath.startsWith('http') ? audioPath : '${_adhook.baseUrl}$audioPath';
      return AudioBubble(url: audioUrl, isMe: isMe);
    }

    if (typeLower == 'file' || mediaUrl.isNotEmpty || lowerContent.contains('/uploads/')) {
      return _buildFileContent(msg, isMe, style);
    }

    return _buildTextContent(msg, isMe, style);
  }

  Widget? _buildInteractiveIcon(String? iconData, Color defaultColor) {
    if (iconData == null || iconData.trim().isEmpty) return null;
    final trimmed = iconData.trim();

    // 1. URL image
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.network(
          trimmed,
          width: 18,
          height: 18,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      );
    }

    // 2. Common material icon mappings
    final iconMap = {
      'lock': Icons.lock_outline_rounded,
      'password': Icons.key_rounded,
      'key': Icons.vpn_key_rounded,
      'email': Icons.email_outlined,
      'mail': Icons.mail_outline_rounded,
      'phone': Icons.phone_outlined,
      'call': Icons.call_outlined,
      'user': Icons.person_outline_rounded,
      'person': Icons.person_outline_rounded,
      'help': Icons.help_outline_rounded,
      'support': Icons.support_agent_rounded,
      'chat': Icons.chat_bubble_outline_rounded,
      'info': Icons.info_outline_rounded,
      'shield': Icons.shield_outlined,
      'security': Icons.security_rounded,
      'card': Icons.credit_card_rounded,
      'payment': Icons.payment_rounded,
      'hospital': Icons.local_hospital_outlined,
      'doctor': Icons.medical_services_outlined,
      'claim': Icons.receipt_long_rounded,
      'file': Icons.insert_drive_file_outlined,
      'document': Icons.description_outlined,
      'settings': Icons.settings_outlined,
      'check': Icons.check_circle_outline_rounded,
      'star': Icons.star_outline_rounded,
      'list': Icons.list_rounded,
      'menu': Icons.menu_rounded,
    };

    final iconKey = trimmed.toLowerCase();
    if (iconMap.containsKey(iconKey)) {
      return Icon(iconMap[iconKey], size: 18, color: defaultColor);
    }

    // 3. Emoji or character
    return Text(trimmed, style: const TextStyle(fontSize: 16));
  }

  Widget _buildButtonContent(AdhookMessage msg, bool isMe, AdhookChatStyle style) {
    Map<String, dynamic> buttonData = {};
    try {
      buttonData = jsonDecode(msg.content);
    } catch (_) {}

    final text = (buttonData['text'] ?? buttonData['body'] ?? buttonData['message'] ?? '').toString().trim();
    final List<_InteractiveItem> items = [];

    void extractItem(dynamic raw) {
      if (raw == null) return;
      if (raw is Map) {
        final map = raw['reply'] is Map ? raw['reply'] : raw;
        final title = (map['title'] ?? map['text'] ?? map['name'] ?? map['label'] ?? '').toString().trim();
        if (title.isEmpty) return;
        final desc = (map['description'] ?? map['desc'] ?? map['subtitle'] ?? map['subtext'])?.toString().trim();
        final icon = (map['icon'] ?? map['icon_url'] ?? map['icon_name'] ?? map['emoji'])?.toString().trim();
        final payload = (map['id'] ?? map['payload'] ?? map['value'] ?? title).toString().trim();
        items.add(_InteractiveItem(
          title: title,
          description: desc != null && desc.isNotEmpty ? desc : null,
          icon: icon != null && icon.isNotEmpty ? icon : null,
          payload: payload.isNotEmpty ? payload : title,
        ));
      } else {
        final t = raw.toString().trim();
        if (t.isNotEmpty) {
          items.add(_InteractiveItem(title: t, payload: t));
        }
      }
    }

    if (buttonData['buttons'] is List) {
      for (var b in buttonData['buttons']) {
        extractItem(b);
      }
    }

    if (items.isEmpty && buttonData['sections'] is List) {
      for (var sec in buttonData['sections']) {
        if (sec is Map && sec['rows'] is List) {
          for (var r in sec['rows']) {
            extractItem(r);
          }
        }
      }
    }

    if (items.isEmpty && buttonData['rows'] is List) {
      for (var r in buttonData['rows']) {
        extractItem(r);
      }
    }

    if (items.isEmpty && buttonData['items'] is List) {
      for (var item in buttonData['items']) {
        extractItem(item);
      }
    }

    if (items.isEmpty && buttonData['options'] is List) {
      for (var opt in buttonData['options']) {
        extractItem(opt);
      }
    }

    final isList = msg.type.toUpperCase() == 'LIST' ||
        buttonData['sections'] != null ||
        buttonData['rows'] != null ||
        items.any((i) => i.description != null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12.0),
            child: Text(
              text,
              style: style.applyFont(isMe ? style.visitorTextStyle : style.agentTextStyle),
            ),
          ),
        if (items.isNotEmpty)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: items.map((item) {
              final iconWidget = _buildInteractiveIcon(
                item.icon,
                isList
                    ? (style.brightness == Brightness.dark ? Colors.white70 : Colors.black87)
                    : Colors.white,
              );

              return Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(style.buttonRadius + 4),
                    onTap: () {
                      if (item.payload == 'ACTION_CALL_AGENT' ||
                          item.title.toLowerCase().contains('telepon agen') ||
                          item.title.toLowerCase().contains('telepon cs')) {
                        _startVoiceCall(context);
                      } else {
                        _adhook.sendMessage(item.title);
                      }
                    },
                    child: Ink(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        gradient: isList
                            ? null
                            : LinearGradient(
                                colors: [style.primaryColor, style.primaryColor.withValues(alpha: 0.9)],
                              ),
                        color: isList
                            ? (style.brightness == Brightness.dark ? const Color(0xFF2A2A2A) : const Color(0xFFF3F4F6))
                            : null,
                        borderRadius: BorderRadius.circular(style.buttonRadius + 4),
                        border: isList
                            ? Border.all(
                                color: style.brightness == Brightness.dark ? Colors.white12 : Colors.black12,
                                width: 1,
                              )
                            : null,
                        boxShadow: [
                          BoxShadow(
                            color: (isList ? Colors.black : style.primaryColor).withValues(alpha: isList ? 0.04 : 0.25),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          )
                        ],
                      ),
                      child: Row(
                        children: [
                          if (iconWidget != null) ...[
                            iconWidget,
                            const SizedBox(width: 10),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.title,
                                  style: style.applyFont(TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: isList
                                        ? (style.brightness == Brightness.dark ? Colors.white : Colors.black87)
                                        : Colors.white,
                                  )),
                                ),
                                if (item.description != null) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    item.description!,
                                    style: style.applyFont(TextStyle(
                                      fontSize: 11,
                                      color: isList
                                          ? (style.brightness == Brightness.dark ? Colors.white60 : Colors.black54)
                                          : Colors.white70,
                                    )),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (isList)
                            Icon(
                              Icons.arrow_forward_ios_rounded,
                              size: 12,
                              color: style.brightness == Brightness.dark ? Colors.white38 : Colors.black38,
                            )
                          else
                            const Icon(
                              Icons.touch_app_outlined,
                              size: 14,
                              color: Colors.white70,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _buildImageContent(AdhookMessage msg, String url, bool isMe, AdhookChatStyle style) {
    final hasCaption = msg.content.isNotEmpty && msg.content != url && msg.content != msg.mediaUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => _onImageTap(url),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              url,
              width: 220,
              fit: BoxFit.cover,
              errorBuilder: (c, e, s) => Container(
                width: 220,
                height: 120,
                color: Colors.grey[200],
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.broken_image_rounded, color: Colors.grey, size: 28),
                    SizedBox(height: 4),
                    Text(
                      'Gagal memuat gambar',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (hasCaption) ...[
          const SizedBox(height: 6),
          Text(msg.content, style: style.applyFont(isMe ? style.visitorTextStyle : style.agentTextStyle)),
        ],
      ],
    );
  }

  Widget _buildLocationBubble(String content, bool isMe, AdhookChatStyle style) {
    double? lat, lng;
    try {
      if (content.contains('{')) {
        final data = jsonDecode(content); lat = data['latitude']; lng = data['longitude'];
      } else if (content.contains(',')) {
        final parts = content.split(','); lat = double.parse(parts[0]); lng = double.parse(parts[1]);
      }
    } catch (_) {}
    if (lat == null || lng == null) return Text(content, style: isMe ? style.visitorTextStyle : style.agentTextStyle);
    final mapUrl = "https://www.google.com/maps/search/?api=1&query=$lat,$lng";
    final previewUrl = "https://static-maps.yandex.ru/1.x/?lang=en_US&ll=$lng,$lat&z=15&l=map&size=300,150&pt=$lng,$lat,pm2rdm";
    return InkWell(
      onTap: () => _openUrl(mapUrl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.network(previewUrl, width: 220, height: 110, fit: BoxFit.cover, errorBuilder: (c, e, s) => Container(width: 220, height: 110, color: Colors.grey[300], child: const Icon(Icons.map)))),
        const SizedBox(height: 8),
        Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.location_on, size: 14, color: isMe ? Colors.white : Colors.red), const SizedBox(width: 4), Text("Shared Location", style: style.applyFont(TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isMe ? Colors.white : (style.brightness == Brightness.dark ? Colors.white70 : Colors.black87))))]),
        Text("Click to view on Maps", style: style.applyFont(TextStyle(fontSize: 10, color: isMe ? Colors.white70 : Colors.grey))),
      ]),
    );
  }

  Widget _buildConnectionStatus(AdhookChatStyle style) {
    return StreamBuilder<AdhookConnectionStatus>(
      stream: _adhook.connectionStatus,
      initialData: AdhookConnectionStatus.connected,
      builder: (context, snapshot) {
        final status = snapshot.data;
        if (status == AdhookConnectionStatus.connected) return const SizedBox.shrink();

        final isDark = style.brightness == Brightness.dark;
        final bool reconnecting = status == AdhookConnectionStatus.disconnected;
        final Color accent = reconnecting ? const Color(0xFFD97706) : style.primaryColor;

        final banner = Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: isDark
                ? reconnecting
                    ? const Color(0xFF3A2E16)
                    : Colors.white.withValues(alpha: 0.07)
                : reconnecting
                    ? const Color(0xFFFFF7E0)
                    : const Color(0xFFF1F6FF),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : reconnecting
                      ? const Color(0xFFF0DCA8)
                      : const Color(0xFFD8E5FF),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.05),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(accent),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  reconnecting
                      ? "Koneksi terputus, menghubungkan kembali..."
                      : "Menghubungkan...",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style.applyFont(TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: isDark
                        ? Colors.white70
                        : reconnecting
                            ? const Color(0xFF8A5A08)
                            : const Color(0xFF33558A),
                  )),
                ),
              ),
            ],
          ),
        );

        return Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: KeyedSubtree(
                key: ValueKey(reconnecting ? 'disconnected' : 'connecting'),
                child: banner,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildUploadProgressIndicator(AdhookChatStyle style) {
    return StreamBuilder<bool>(
      stream: _adhook.uploadStatusStream,
      initialData: _adhook.isUploading,
      builder: (context, snapshot) {
        if (snapshot.data != true) return const SizedBox.shrink();
        
        final isDark = style.brightness == Brightness.dark;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFEFF6FF),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : const Color(0xFFBFDBFE),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(style.primaryColor),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "Uploading media file...",
                      style: style.applyFont(TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF1E3A8A),
                      )),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Please wait, sending to server...",
                      style: style.applyFont(TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white60 : const Color(0xFF3B82F6),
                      )),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.cloud_upload_rounded,
                color: style.primaryColor,
                size: 20,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTextContent(AdhookMessage msg, bool isMe, AdhookChatStyle style) {
    final hasUrl = msg.content.contains(RegExp(r'(https?:\/\/[^\s]+)'));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(msg.content, style: style.applyFont(isMe ? style.visitorTextStyle : style.agentTextStyle)),
      if (hasUrl) ...[const SizedBox(height: 8), _buildLinkPreview(msg, style)],
    ]);
  }

  Widget _buildLinkPreview(AdhookMessage msg, AdhookChatStyle style) {
    return LinkPreview(
      enableAnimation: true,
      onPreviewDataFetched: (data) {
        setState(() => _previewDataCache[msg.id] = data);
      },
      previewData: _previewDataCache[msg.id],
      text: msg.content,
      width: 220,
    );
  }

  Widget _buildFileContent(AdhookMessage msg, bool isMe, AdhookChatStyle style) {
    final filePath = (msg.mediaUrl != null && msg.mediaUrl!.isNotEmpty) ? msg.mediaUrl! : msg.content;
    final url = filePath.startsWith('http') ? filePath : '${_adhook.baseUrl}$filePath';
    final lowerUrl = url.toLowerCase();
    if (lowerUrl.contains(RegExp(r'\.(jpg|jpeg|png|gif|webp)'))) return _buildImageContent(msg, url, isMe, style);
    if (lowerUrl.contains(RegExp(r'\.(mp4|mov|avi|mkv|webm|3gp|m4v)'))) return _buildVideoCard(url, isMe, style);
    if (lowerUrl.contains('.pdf')) return _buildPdfCard(url, isMe, style);
    return _buildGenericFile(url, isMe, style);
  }

  Widget _buildVideoCard(String url, bool isMe, AdhookChatStyle style) => InkWell(
    onTap: () => _openUrl(url),
    child: Container(
      width: 200,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isMe ? Colors.white24 : (style.brightness == Brightness.dark ? Colors.white10 : Colors.black.withValues(alpha: 0.05)),
        borderRadius: BorderRadius.circular(12)
      ),
      child: Row(
        children: [
          const Icon(Icons.video_library_rounded, color: Color(0xFF6366F1), size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Video Media", style: style.applyFont(const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                Text(url.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis, style: style.applyFont(const TextStyle(fontSize: 10, color: Colors.grey))),
              ],
            ),
          ),
          const Icon(Icons.play_circle_fill_rounded, color: Color(0xFF6366F1), size: 22),
        ],
      ),
    ),
  );

  Widget _buildPdfCard(String url, bool isMe, AdhookChatStyle style) => InkWell(onTap: () => _openUrl(url), child: Container(width: 180, padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: isMe ? Colors.white24 : (style.brightness == Brightness.dark ? Colors.white10 : Colors.black.withValues(alpha: 0.05)), borderRadius: BorderRadius.circular(12)), child: Row(children: [const Icon(Icons.picture_as_pdf_rounded, color: Color(0xFFEF4444), size: 32), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text("PDF Document", style: style.applyFont(const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))), Text(url.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis, style: style.applyFont(const TextStyle(fontSize: 10, color: Colors.grey)))]))])));

  Widget _buildGenericFile(String url, bool isMe, AdhookChatStyle style) => InkWell(onTap: () => _openUrl(url), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.insert_drive_file_outlined, color: isMe ? Colors.white : style.primaryColor, size: 20), const SizedBox(width: 8), Flexible(child: Text("Document", style: style.applyFont(isMe ? style.visitorTextStyle : style.agentTextStyle), overflow: TextOverflow.ellipsis))]));

  void _openUrl(String url) async { final uri = Uri.parse(url); if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication); }

  Widget _buildForm(AdhookChatStyle style) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
    child: Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      color: style.brightness == Brightness.dark ? const Color(0xFF1E1E1E) : Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch, 
          children: [
            Text("Welcome to Live Support", style: style.applyFont(const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text("Please complete your profile to start the chat.", style: style.applyFont(const TextStyle(fontSize: 13, color: Colors.grey)), textAlign: TextAlign.center),
            const SizedBox(height: 24), 
            _buildTextField(controller: _nameController, label: "Full Name", icon: Icons.person_outline, style: style), 
            const SizedBox(height: 16), 
            _buildTextField(controller: _emailController, label: "Email Address", icon: Icons.email_outlined, keyboardType: TextInputType.emailAddress, style: style), 
            const SizedBox(height: 16), 
            _buildTextField(controller: _phoneController, label: "Phone Number", icon: Icons.phone_android_outlined, keyboardType: TextInputType.phone, style: style), 
            const SizedBox(height: 30), 
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: style.primaryColor, 
                foregroundColor: Colors.white, 
                padding: const EdgeInsets.symmetric(vertical: 16), 
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 2,
              ), 
              onPressed: () { 
                if (_nameController.text.trim().isEmpty) return; 
                _adhook.setUserInfo(name: _nameController.text.trim(), email: _emailController.text.trim(), phone: _phoneController.text.trim()); 
                setState(() => _showForm = false); 
                _adhook.connect(); 
              }, 
              child: Text("Start Chat", style: style.applyFont(const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)))
            )
          ]
        ),
      ),
    ),
  );

  Widget _buildTextField({required TextEditingController controller, required String label, required IconData icon, required AdhookChatStyle style, TextInputType keyboardType = TextInputType.text}) => TextField(
    controller: controller, 
    keyboardType: keyboardType, 
    style: style.applyFont(const TextStyle(fontSize: 14)), 
    decoration: InputDecoration(
      labelText: label, 
      labelStyle: style.applyFont(const TextStyle(fontSize: 13, color: Colors.grey)), 
      prefixIcon: Icon(icon, color: style.primaryColor, size: 20),
      filled: true,
      fillColor: style.brightness == Brightness.dark ? Colors.white10 : Colors.grey[50],
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    )
  );

  Widget _buildInputArea(AdhookChatStyle style) {
    if (_adhook.isConversationClosed) {
      return _buildClosedBar(style);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: style.brightness == Brightness.dark ? const Color(0xFF1E1E1E) : Colors.white, 
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: style.brightness == Brightness.dark ? 0.3 : 0.05), 
            offset: const Offset(0, -2), 
            blurRadius: 8
          )
        ]
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_replyingTo != null) _buildReplyInputBar(style),
          SafeArea(
            top: false,
            child: Row(
              children: [
                if (style.allowAttachment) 
                  IconButton(
                    icon: Icon(Icons.add_circle_outline_rounded, color: Colors.grey[600], size: 26), 
                    onPressed: () => _showAttachmentSheet(style)
                  ),
                if (style.allowLocationSharing) 
                  IconButton(
                    icon: Icon(Icons.location_on_outlined, color: Colors.grey[600], size: 26), 
                    onPressed: _handleLocation
                  ),
                const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: style.brightness == Brightness.dark ? Colors.white10 : Colors.grey[100],
                      borderRadius: BorderRadius.circular(24),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: _isRecording 
                      ? Row(children: [const Icon(Icons.mic, color: Color(0xFFEF4444), size: 18), const SizedBox(width: 8), Expanded(child: _buildWaveform())])
                      : TextField(
                          controller: _controller, 
                          onChanged: _onTextChanged, 
                          style: style.applyFont(const TextStyle(fontSize: 14)), 
                          decoration: InputDecoration(
                            hintText: 'Type a message...', 
                            hintStyle: style.applyFont(const TextStyle(fontSize: 14, color: Colors.grey)), 
                            border: InputBorder.none, 
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10)
                          ), 
                          onSubmitted: (_) => _handleSend()
                        ),
                  ),
                ),
                const SizedBox(width: 6),
                if (style.allowVoiceRecording && _controller.text.isEmpty)
                  GestureDetector(
                    onLongPressStart: (_) => _startRecording(), 
                    onLongPressEnd: (_) => _stopRecording(), 
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _isRecording ? const Color(0xFFEF4444).withValues(alpha: 0.1) : Colors.transparent,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _isRecording ? Icons.mic : Icons.mic_none_rounded, 
                        color: _isRecording ? const Color(0xFFEF4444) : Colors.grey[600],
                        size: 24
                      )
                    )
                  ),
                if (_controller.text.isNotEmpty) 
                  GestureDetector(
                    onTap: _handleSend,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: style.primaryColor,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClosedBar(AdhookChatStyle style) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: style.brightness == Brightness.dark ? const Color(0xFF1E1E1E) : Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: style.brightness == Brightness.dark ? 0.3 : 0.05),
            offset: const Offset(0, -2),
            blurRadius: 8,
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Icon(Icons.lock_outline_rounded, color: Colors.grey[600], size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Percakapan ini telah diakhiri.',
                style: style.applyFont(TextStyle(
                  fontSize: 13,
                  color: style.brightness == Brightness.dark ? Colors.white70 : Colors.grey[700],
                )),
              ),
            ),
            TextButton.icon(
              onPressed: () async {
                await _adhook.startNewConversation();
              },
              icon: const Icon(Icons.add_comment_outlined, size: 18),
              label: const Text('Mulai Chat Baru'),
              style: TextButton.styleFrom(foregroundColor: style.primaryColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReplyInputBar(AdhookChatStyle style) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: style.brightness == Brightness.dark ? Colors.white10 : Colors.black.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(8), border: Border(left: BorderSide(color: style.primaryColor, width: 4))),
      child: Row(
        children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_replyingTo!.senderName ?? "Replying to", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: style.primaryColor)),
            Text(_replyingTo!.content, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ])),
          IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _replyingTo = null)),
        ],
      ),
    );
  }

  Widget _buildWaveform() {
    final normalizedAmp = (math.max(-60.0, _amplitude) + 60.0) / 60.0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center, 
      children: List.generate(20, (index) {
        final height = 4.0 + (normalizedAmp * 20.0 * math.Random().nextDouble());
        return Container(
          width: 3, 
          height: height, 
          margin: const EdgeInsets.symmetric(horizontal: 1.5), 
          decoration: BoxDecoration(
            color: const Color(0xFFEF4444), 
            borderRadius: BorderRadius.circular(2)
          )
        );
      })
    );
  }

  void _showHistoryBottomSheet(BuildContext context) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _HistoryListOverlay(
          adhook: _adhook,
          style: widget.style,
          onSelectConversation: (conv) async {
            Navigator.pop(ctx);
            final rawId = conv['id'];
            final conversationId = rawId is int ? rawId : int.tryParse('$rawId');
            if (conversationId == null) return;
            final sessionId = (conv['session_id'] as String?) ?? '';
            final isClosed = conv['is_active'] != true;
            await _adhook.openConversation(
              conversationId: conversationId,
              sessionId: sessionId.isEmpty ? null : sessionId,
              isClosed: isClosed,
            );
          },
          onNewChat: () async {
            Navigator.pop(ctx);
            await _adhook.startNewConversation();
          },
        );
      },
    );
  }

  void _startVoiceCall(BuildContext context) async {
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _VoiceCallOverlay(
          adhook: _adhook,
          style: widget.style,
        );
      },
    );
  }

  void _handleSend() {
    if (_controller.text.trim().isEmpty) return;
    _typingTimer?.cancel();
    _adhook.sendMessage(_controller.text.trim(), replyToId: _replyingTo?.id);
    _controller.clear();
    setState(() => _replyingTo = null);
  }
}

class _VoiceCallOverlay extends StatefulWidget {
  final AdhookChat adhook;
  final AdhookChatStyle style;

  const _VoiceCallOverlay({required this.adhook, required this.style});

  @override
  State<_VoiceCallOverlay> createState() => _VoiceCallOverlayState();
}

class _VoiceCallOverlayState extends State<_VoiceCallOverlay> {
  bool _isConnecting = true;
  bool _isConnected = false;
  bool _isMuted = false;
  bool _isSpeakerOn = true;
  int _callSeconds = 0;
  Timer? _timer;
  String? _roomName;
  String? _egressId;
  String? _errorMessage;
  StreamSubscription? _callSub;
  Room? _livekitRoom;
  EventsListener<RoomEvent>? _roomListener;

  @override
  void initState() {
    super.initState();
    _initiateCall();

    _callSub = widget.adhook.callEventStream.listen((event) {
      final eventName = event['event'];
      if (eventName == 'CALL_ENDED' || eventName == 'CALL_REJECTED') {
        if (mounted) {
          _cleanupAndPop();
        }
      }
    });
  }

  void _initiateCall() async {
    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });
    try {
      final res = await widget.adhook.initiateVoiceCall();
      _roomName = res['room_name'];
      _egressId = res['egress_id'];
      final token = res['token'];
      final wsUrl = res['ws_url'];
      if (wsUrl == null || wsUrl.toString().isEmpty) {
        throw Exception('Server tidak menyediakan URL koneksi panggilan suara.');
      }

      if (token != null && token.toString().isNotEmpty) {
        try {
          _livekitRoom = Room(
            roomOptions: const RoomOptions(
              adaptiveStream: false,
              dynacast: false,
            ),
          );
          _roomListener = _livekitRoom!.createListener();
          _roomListener!.on<TrackSubscribedEvent>((event) {
            if (event.track is AudioTrack) {
              event.track.start();
            }
          });

          await _livekitRoom!.connect(wsUrl, token.toString());
          await _livekitRoom!.localParticipant?.setMicrophoneEnabled(true);
          try {
            await Hardware.instance.setSpeakerphoneOn(true);
          } catch (_) {}
        } catch (e) {
          debugPrint('[VoiceCallOverlay] LiveKit WebRTC error: $e');
        }
      }

      if (mounted) {
        setState(() {
          _isConnecting = false;
          _isConnected = true;
          _errorMessage = null;
        });
        _startTimer();
      }
    } catch (e) {
      if (mounted) {
        final errorText = e.toString().replaceFirst('Exception: ', '');
        setState(() {
          _isConnecting = false;
          _errorMessage = errorText;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorText),
            backgroundColor: Colors.red[700],
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _callSeconds = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (mounted) {
        setState(() {
          _callSeconds++;
        });
      }
    });
  }

  void _cleanupAndPop() async {
    _timer?.cancel();
    _callSub?.cancel();
    try {
      await _livekitRoom?.localParticipant?.setMicrophoneEnabled(false);
      await _livekitRoom?.disconnect();
      await _livekitRoom?.dispose();
    } catch (_) {}
    if (Navigator.canPop(context)) {
      Navigator.of(context).pop();
    }
  }

  void _endCall() async {
    if (_roomName != null) {
      await widget.adhook.endVoiceCall(roomName: _roomName!, egressId: _egressId);
    }
    _cleanupAndPop();
  }

  void _toggleMute() async {
    final newMute = !_isMuted;
    setState(() {
      _isMuted = newMute;
    });
    try {
      await _livekitRoom?.localParticipant?.setMicrophoneEnabled(!newMute);
    } catch (_) {}
  }

  void _toggleSpeaker() async {
    final newSpeaker = !_isSpeakerOn;
    setState(() {
      _isSpeakerOn = newSpeaker;
    });
    try {
      await Hardware.instance.setSpeakerphoneOn(newSpeaker);
    } catch (e) {
      debugPrint('[VoiceCallOverlay] Hardware speaker error: $e');
    }
  }

  String _formatTimer(int seconds) {
    final mins = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return "$mins:$secs";
  }

  @override
  void dispose() {
    _timer?.cancel();
    _callSub?.cancel();
    try {
      _livekitRoom?.disconnect();
      _livekitRoom?.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = widget.style.primaryColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 20, offset: Offset(0, -4))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: const [
                  Icon(Icons.phone_in_talk_rounded, color: Color(0xFF0284C7), size: 20),
                  SizedBox(width: 8),
                  Text(
                    "ADMEDIKA VOICE SYSTEM",
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0284C7), letterSpacing: 0.5),
                  ),
                ],
              ),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(8)),
                  child: const Text("Sembunyikan", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF475569))),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: primaryColor,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: primaryColor.withValues(alpha: 0.3), blurRadius: 16, offset: const Offset(0, 6))],
            ),
            child: const Center(
              child: Text("CS", style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 16),
          const Text("CS Agent AdMedika", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
          const SizedBox(height: 4),
          Text(
            _isConnecting
                ? "Menghubungkan ke CS AdMedika..."
                : (_isConnected 
                    ? "🟢 Terhubung ke CS Agent" 
                    : (_errorMessage != null 
                        ? "⚠️ $_errorMessage" 
                        : "❌ Panggilan Berakhir")),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13, 
              color: _isConnected 
                  ? const Color(0xFF10B981) 
                  : (_errorMessage != null ? const Color(0xFFEF4444) : Colors.grey[600]), 
              fontWeight: FontWeight.w600,
            ),
          ),
          if (_errorMessage != null && !_isConnecting && !_isConnected) ...[
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _initiateCall,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text("Coba Hubungi Lagi"),
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              ),
            ),
          ],
          if (_isConnected) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Text(
                _formatTimer(_callSeconds),
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, fontFamily: 'monospace', color: Color(0xFF0F172A)),
              ),
            ),
          ],
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _toggleMute,
                  icon: Icon(_isMuted ? Icons.mic_off_rounded : Icons.mic_rounded, size: 20),
                  label: Text(_isMuted ? "Unmute" : "Mute", style: const TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isMuted ? const Color(0xFFFEF3C7) : const Color(0xFFF1F5F9),
                    foregroundColor: _isMuted ? const Color(0xFFB45309) : const Color(0xFF334155),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _toggleSpeaker,
                  icon: Icon(_isSpeakerOn ? Icons.volume_up_rounded : Icons.volume_down_rounded, size: 20),
                  label: Text(_isSpeakerOn ? "Speaker" : "Earpiece", style: const TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isSpeakerOn ? const Color(0xFFE0F2FE) : const Color(0xFFF1F5F9),
                    foregroundColor: _isSpeakerOn ? const Color(0xFF0369A1) : const Color(0xFF334155),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _endCall,
                  icon: const Icon(Icons.phone_disabled_rounded, size: 20),
                  label: const Text("Akhiri", style: TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFF43F5E),
                    foregroundColor: Colors.white,
                    elevation: 2,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HistoryListOverlay extends StatefulWidget {
  final AdhookChat adhook;
  final AdhookChatStyle style;
  final void Function(Map<String, dynamic> conv) onSelectConversation;
  final VoidCallback onNewChat;

  const _HistoryListOverlay({
    required this.adhook,
    required this.style,
    required this.onSelectConversation,
    required this.onNewChat,
  });

  @override
  State<_HistoryListOverlay> createState() => _HistoryListOverlayState();
}

class _HistoryListOverlayState extends State<_HistoryListOverlay> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _conversations = [];

  @override
  void initState() {
    super.initState();
    _loadConversations();
  }

  void _loadConversations() async {
    final list = await widget.adhook.fetchConversationsList();
    if (mounted) {
      setState(() {
        _conversations = list;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.style.brightness == Brightness.dark;
    final primaryColor = widget.style.primaryColor;

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 20, offset: Offset(0, -4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.history_rounded, color: primaryColor, size: 22),
                  const SizedBox(width: 8),
                  Text(
                    "Riwayat Percakapan",
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                  ),
                ],
              ),
              ElevatedButton.icon(
                onPressed: widget.onNewChat,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text("Chat Baru"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  elevation: 1,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : (_conversations.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.chat_bubble_outline_rounded, size: 48, color: Colors.grey[400]),
                            const SizedBox(height: 12),
                            Text("Belum ada riwayat percakapan", style: TextStyle(color: Colors.grey[500], fontSize: 14)),
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: _conversations.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final conv = _conversations[index];
                          final id = conv['id'];
                          final lastMsg = conv['last_message'] ?? 'Belum ada pesan';
                          final isActive = conv['is_active'] == true;
                          final dateStr = conv['last_message_at'] != null
                              ? DateFormat('dd MMM, HH:mm').format(DateTime.parse(conv['last_message_at']).toLocal())
                              : '';

                          return Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => widget.onSelectConversation(conv),
                              borderRadius: BorderRadius.circular(14),
                              child: Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF8FAFC),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          "Percakapan #$id",
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.bold,
                                            color: isDark ? Colors.white : const Color(0xFF1E293B),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: isActive ? const Color(0xFFECFDF5) : const Color(0xFFF1F5F9),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(
                                              color: isActive ? const Color(0xFFA7F3D0) : const Color(0xFFE2E8F0),
                                            ),
                                          ),
                                          child: Text(
                                            isActive ? "🟢 Aktif" : "⚪ Selesai",
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: isActive ? const Color(0xFF059669) : const Color(0xFF64748B),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      lastMsg,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: isDark ? Colors.white70 : const Color(0xFF475569),
                                      ),
                                    ),
                                    if (dateStr.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: Text(
                                          dateStr,
                                          style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      )),
          ),
        ],
      ),
    );
  }
}

class FullImageViewer extends StatelessWidget {
  final String url;
  const FullImageViewer({super.key, required this.url});
  @override Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent, 
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white)
      ),
      body: PhotoView(imageProvider: NetworkImage(url), minScale: PhotoViewComputedScale.contained, maxScale: PhotoViewComputedScale.covered * 2),
    );
  }
}

class AudioBubble extends StatefulWidget {
  final String url; final bool isMe; const AudioBubble({super.key, required this.url, required this.isMe});
  @override State<AudioBubble> createState() => _AudioBubbleState();
}
class _AudioBubbleState extends State<AudioBubble> {
  final _player = AudioPlayer(); bool _isPlaying = false; Duration _duration = Duration.zero; Duration _position = Duration.zero;
  @override void initState() { super.initState(); _initPlayer(); }
  Future<void> _initPlayer() async { try { await _player.setUrl(widget.url); _player.durationStream.listen((d) => setState(() => _duration = d ?? Duration.zero)); _player.positionStream.listen((p) => setState(() => _position = p)); _player.playerStateStream.listen((s) => setState(() => _isPlaying = s.playing)); } catch (e) { debugPrint("Player error: $e"); } }
  @override void dispose() { _player.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) { return Container(width: 200, padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [IconButton(icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: widget.isMe ? Colors.white : Colors.blue), onPressed: () => _isPlaying ? _player.pause() : _player.play()), Expanded(child: Slider(value: _position.inSeconds.toDouble(), max: _duration.inSeconds.toDouble() > 0 ? _duration.inSeconds.toDouble() : 1.0, activeColor: widget.isMe ? Colors.white : Colors.blue, inactiveColor: widget.isMe ? Colors.white24 : Colors.black12, onChanged: (v) => _player.seek(Duration(seconds: v.toInt()))))])); }
}

class _InteractiveItem {
  final String title;
  final String? description;
  final String? icon;
  final String payload;

  _InteractiveItem({
    required this.title,
    this.description,
    this.icon,
    required this.payload,
  });
}
