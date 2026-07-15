import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

class _AdhookChatWindowState extends State<AdhookChatWindow> with TickerProviderStateMixin {
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

  @override
  void initState() {
    super.initState();
    _showForm = !_adhook.hasUserInfo;
    if (!_showForm) {
      _adhook.connect();
    }
    
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
    
    _adhook.messageHistory.listen((messages) {
       if (messages.isNotEmpty && messages.last.type == 'system' && messages.last.content == 'conversation_closed') {
         _showRatingDialog();
       }
    });
  }

  @override
  void dispose() {
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
              onPressed: () => Navigator.pop(context), 
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
              onPressed: () {
                _adhook.submitRating(selectedRating, commentController.text.trim());
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text("Thank you for your feedback!"),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  )
                );
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent, 
          duration: const Duration(milliseconds: 400), 
          curve: Curves.fastOutSlowIn
        );
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
              leadingWidth: widget.leading != null ? 70 : null,
              leading: widget.leading != null ? Padding(padding: const EdgeInsets.only(left: 12), child: Center(child: widget.leading)) : null,
              title: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white38, width: 1.5),
                    ),
                    child: const Icon(Icons.support_agent_rounded, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start, 
                      children: [
                        Text(widget.title, style: style.applyFont(style.appBarTitleStyle ?? const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white))),
                        StreamBuilder<bool>(
                          stream: _adhook.agentTypingStatus,
                          initialData: false,
                          builder: (context, snapshot) {
                            if (snapshot.data == true) {
                              return const Text(
                                "Agent is typing...", 
                                style: TextStyle(fontSize: 10, color: Colors.white70, fontStyle: FontStyle.italic, fontWeight: FontWeight.w500)
                              );
                            }
                            return Row(
                              children: [
                                Container(width: 6, height: 6, decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle)),
                                const SizedBox(width: 4),
                                const Text("Always Active", style: TextStyle(fontSize: 10, color: Colors.white70, fontWeight: FontWeight.w500)),
                              ],
                            );
                          },
                        ),
                      ]
                    ),
                  ),
                ],
              ),
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
                    child: StreamBuilder<List<AdhookMessage>>(
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
                            final isMe = msg.sender == AdhookSender.visitor;
                            return GestureDetector(
                              onLongPress: () => setState(() => _replyingTo = msg),
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 14),
                                child: Column(
                                  crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                  children: [
                                    if (!isMe && msg.senderName != null)
                                      Padding(
                                        padding: const EdgeInsets.only(left: 6, bottom: 4), 
                                        child: Text(
                                          msg.senderName!, 
                                          style: style.applyFont(const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey))
                                        )
                                      ),
                                    Align(
                                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                                      child: Container(
                                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
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
                                                  Icon(msg.isRead ? Icons.done_all : Icons.done, size: 13, color: msg.isRead ? Colors.blueAccent : Colors.white60),
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
                  ),
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

  Widget _buildMessageBody(AdhookMessage msg, bool isMe, AdhookChatStyle style) {
    if (msg.type == 'system') return Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 8.0), child: Text(msg.content, style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Colors.grey))));
    if (msg.type == 'BUTTON') return _buildButtonContent(msg, isMe, style);
    final lowerContent = msg.content.toLowerCase();
    if (msg.type == 'location' || lowerContent.startsWith('lat:')) return _buildLocationBubble(msg.content, isMe, style);
    if (lowerContent.contains(RegExp(r'\.(m4a|mp3|wav|aac)'))) return AudioBubble(url: msg.content.startsWith('http') ? msg.content : '${_adhook.baseUrl}${msg.content}', isMe: isMe);
    if (msg.type == 'file' || msg.content.contains('/uploads/')) return _buildFileContent(msg, isMe, style);
    return _buildTextContent(msg, isMe, style);
  }

  Widget _buildButtonContent(AdhookMessage msg, bool isMe, AdhookChatStyle style) {
    Map<String, dynamic> buttonData = {};
    try {
      buttonData = jsonDecode(msg.content);
    } catch (_) {}

    final text = buttonData['text'] ?? '';
    final buttons = List<String>.from(buttonData['buttons'] ?? []);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: style.applyFont(isMe ? style.visitorTextStyle : style.agentTextStyle)),
        if (buttons.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: buttons.map((btnText) {
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(style.buttonRadius + 4),
                  onTap: () {
                    _adhook.sendMessage(btnText);
                  },
                  child: Ink(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [style.primaryColor, style.primaryColor.withValues(alpha: 0.9)],
                      ),
                      borderRadius: BorderRadius.circular(style.buttonRadius + 4),
                      boxShadow: [
                        BoxShadow(
                          color: style.primaryColor.withValues(alpha: 0.25),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        )
                      ]
                    ),
                    child: Text(
                      btnText, 
                      style: style.applyFont(const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white))
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
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
        String text = status == AdhookConnectionStatus.disconnected ? "Connection lost. Reconnecting..." : "Connecting...";
        Color color = status == AdhookConnectionStatus.disconnected ? const Color(0xFFEF4444) : const Color(0xFFF59E0B);
        return Container(
          width: double.infinity, 
          padding: const EdgeInsets.symmetric(vertical: 6), 
          color: color, 
          child: Text(text, textAlign: TextAlign.center, style: style.applyFont(const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)))
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
    final url = msg.content.startsWith('http') ? msg.content : '${_adhook.baseUrl}${msg.content}';
    final lowerUrl = url.toLowerCase();
    if (lowerUrl.contains(RegExp(r'\.(jpg|jpeg|png|gif|webp)'))) return GestureDetector(onTap: () => _onImageTap(url), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.network(url, width: 200, fit: BoxFit.cover, errorBuilder: (c, e, s) => const Icon(Icons.broken_image))));
    if (lowerUrl.contains('.pdf')) return _buildPdfCard(url, isMe, style);
    return _buildGenericFile(url, isMe, style);
  }

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
                    onPressed: () => _adhook.pickAndUploadFile()
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

  void _handleSend() {
    if (_controller.text.trim().isEmpty) return;
    _typingTimer?.cancel();
    _adhook.sendMessage(_controller.text.trim(), replyToId: _replyingTo?.id);
    _controller.clear();
    setState(() => _replyingTo = null);
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
