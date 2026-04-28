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

class _AdhookChatWindowState extends State<AdhookChatWindow> {
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
  
  // Link Preview Cache to prevent flickering
  final Map<int, PreviewData> _previewDataCache = {};

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
            content: Text("Error: $error"),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
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
          backgroundColor: widget.style.agentBubbleColor,
          title: Text("Rate Our Service", textAlign: TextAlign.center, style: TextStyle(color: widget.style.brightness == Brightness.dark ? Colors.white : Colors.black)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("How was your experience with our agent?", style: TextStyle(fontSize: 14, color: widget.style.brightness == Brightness.dark ? Colors.white70 : Colors.black87), textAlign: TextAlign.center),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (index) => IconButton(
                  icon: Icon(index < selectedRating ? Icons.star : Icons.star_border, color: Colors.amber, size: 32),
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
                  hintStyle: const TextStyle(color: Colors.grey),
                  border: const OutlineInputBorder(),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: widget.style.brightness == Brightness.dark ? Colors.white24 : Colors.black12)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Skip")),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: widget.style.primaryColor, foregroundColor: Colors.white),
              onPressed: () {
                _adhook.submitRating(selectedRating, commentController.text.trim());
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Thank you for your feedback!")));
              },
              child: const Text("Submit"),
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
    if (text.isEmpty) { _adhook.sendTypingStatus(false); return; }
    if (_typingTimer == null || !_typingTimer!.isActive) _adhook.sendTypingStatus(true);
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 3), () => _adhook.sendTypingStatus(false));
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
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
        textTheme: Theme.of(context).textTheme.apply(fontFamily: style.fontFamily, bodyColor: style.brightness == Brightness.dark ? Colors.white : Colors.black87),
      ),
      child: Scaffold(
        backgroundColor: style.backgroundColor,
        appBar: style.showAppBar 
          ? AppBar(
              leadingWidth: widget.leading != null ? 70 : null,
              leading: widget.leading != null ? Padding(padding: const EdgeInsets.only(left: 12), child: Center(child: widget.leading)) : null,
              title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.title, style: style.applyFont(style.appBarTitleStyle ?? const TextStyle())),
                StreamBuilder<bool>(
                  stream: _adhook.agentTypingStatus,
                  initialData: false,
                  builder: (context, snapshot) {
                    if (snapshot.data == true) return Text("Agent is typing...", style: style.applyFont(const TextStyle(fontSize: 10, color: Colors.white70)));
                    return const SizedBox.shrink();
                  },
                ),
              ]),
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
                          padding: const EdgeInsets.all(16),
                          itemCount: messages.length,
                          itemBuilder: (context, index) {
                            final msg = messages[index];
                            final isMe = msg.sender == AdhookSender.visitor;
                            return GestureDetector(
                              onLongPress: () => setState(() => _replyingTo = msg),
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Column(
                                  crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                  children: [
                                    if (!isMe && msg.senderName != null)
                                      Padding(padding: const EdgeInsets.only(left: 4, bottom: 4), child: Text(msg.senderName!, style: style.applyFont(const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)))),
                                    Align(
                                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                                      child: Container(
                                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                                        padding: style.bubblePadding,
                                        decoration: BoxDecoration(
                                          color: isMe ? style.visitorBubbleColor : style.agentBubbleColor,
                                          borderRadius: BorderRadius.circular(style.bubbleRadius).copyWith(bottomRight: isMe ? const Radius.circular(0) : null, bottomLeft: !isMe ? const Radius.circular(0) : null),
                                          boxShadow: [if (style.brightness == Brightness.light) BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(0, 2))]
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            if (msg.replyToContent != null) _buildReplyQuote(msg, isMe, style),
                                            _buildMessageBody(msg, isMe, style),
                                            const SizedBox(height: 4),
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              mainAxisAlignment: MainAxisAlignment.end,
                                              children: [
                                                Text(_formatTime(msg.createdAt), style: style.applyFont(TextStyle(fontSize: 9, color: isMe ? Colors.white70 : Colors.grey))),
                                                if (isMe) ...[
                                                  const SizedBox(width: 4),
                                                  Icon(msg.isRead ? Icons.done_all : Icons.done, size: 12, color: msg.isRead ? Colors.blueAccent : Colors.white60),
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
        color: isMe ? Colors.black12 : (style.brightness == Brightness.dark ? Colors.white10 : Colors.black.withOpacity(0.05)),
        borderRadius: BorderRadius.circular(4),
        border: Border(left: BorderSide(color: style.primaryColor, width: 3)),
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
    final lowerContent = msg.content.toLowerCase();
    if (msg.type == 'location' || lowerContent.startsWith('lat:')) return _buildLocationBubble(msg.content, isMe, style);
    if (lowerContent.contains(RegExp(r'\.(m4a|mp3|wav|aac)'))) return AudioBubble(url: msg.content.startsWith('http') ? msg.content : '${_adhook.baseUrl}${msg.content}', isMe: isMe);
    if (msg.type == 'file' || msg.content.contains('/uploads/')) return _buildFileContent(msg, isMe, style);
    return _buildTextContent(msg, isMe, style);
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
        ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(previewUrl, width: 220, height: 110, fit: BoxFit.cover, errorBuilder: (c, e, s) => Container(width: 220, height: 110, color: Colors.grey[300], child: const Icon(Icons.map)))),
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
        Color color = status == AdhookConnectionStatus.disconnected ? Colors.red : Colors.orange;
        return Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 4), color: color, child: Text(text, textAlign: TextAlign.center, style: style.applyFont(const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold))));
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
    if (lowerUrl.contains(RegExp(r'\.(jpg|jpeg|png|gif|webp)'))) return GestureDetector(onTap: () => _onImageTap(url), child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(url, width: 200, fit: BoxFit.cover, errorBuilder: (c, e, s) => const Icon(Icons.broken_image))));
    if (lowerUrl.contains('.pdf')) return _buildPdfCard(url, isMe, style);
    return _buildGenericFile(url, isMe, style);
  }

  Widget _buildPdfCard(String url, bool isMe, AdhookChatStyle style) => InkWell(onTap: () => _openUrl(url), child: Container(width: 180, padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: isMe ? Colors.white24 : (style.brightness == Brightness.dark ? Colors.white10 : Colors.black.withOpacity(0.05)), borderRadius: BorderRadius.circular(8)), child: Row(children: [const Icon(Icons.picture_as_pdf, color: Colors.red, size: 30), const SizedBox(width: 8), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text("PDF Document", style: style.applyFont(const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))), Text(url.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis, style: style.applyFont(const TextStyle(fontSize: 10, color: Colors.grey)))]))])));

  Widget _buildGenericFile(String url, bool isMe, AdhookChatStyle style) => InkWell(onTap: () => _openUrl(url), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.insert_drive_file, color: isMe ? Colors.white : style.primaryColor), const SizedBox(width: 8), Flexible(child: Text("Document", style: style.applyFont(isMe ? style.visitorTextStyle : style.agentTextStyle), overflow: TextOverflow.ellipsis))]));

  void _openUrl(String url) async { final uri = Uri.parse(url); if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication); }

  Widget _buildForm(AdhookChatStyle style) => SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Text("Please complete your profile to start the chat.", style: style.applyFont(const TextStyle(fontSize: 16, color: Colors.black54)), textAlign: TextAlign.center), const SizedBox(height: 30), _buildTextField(controller: _nameController, label: "Full Name", icon: Icons.person, style: style), const SizedBox(height: 16), _buildTextField(controller: _emailController, label: "Email Address", icon: Icons.email, keyboardType: TextInputType.emailAddress, style: style), const SizedBox(height: 16), _buildTextField(controller: _phoneController, label: "Phone Number", icon: Icons.phone, keyboardType: TextInputType.phone, style: style), const SizedBox(height: 30), ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: style.primaryColor, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(style.buttonRadius))), onPressed: () { if (_nameController.text.trim().isEmpty) return; _adhook.setUserInfo(name: _nameController.text.trim(), email: _emailController.text.trim(), phone: _phoneController.text.trim()); setState(() => _showForm = false); _adhook.connect(); }, child: Text("Start Chat", style: style.applyFont(const TextStyle(fontSize: 16))))]));

  Widget _buildTextField({required TextEditingController controller, required String label, required IconData icon, required AdhookChatStyle style, TextInputType keyboardType = TextInputType.text}) => TextField(controller: controller, keyboardType: keyboardType, style: style.applyFont(const TextStyle(fontSize: 14)), decoration: InputDecoration(labelText: label, labelStyle: style.applyFont(const TextStyle(fontSize: 14)), border: OutlineInputBorder(borderRadius: BorderRadius.circular(style.buttonRadius)), prefixIcon: Icon(icon, color: style.primaryColor)));

  Widget _buildInputArea(AdhookChatStyle style) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: style.brightness == Brightness.dark ? const Color(0xFF1E1E1E) : Colors.white, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), offset: const Offset(0, -1), blurRadius: 5)]),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_replyingTo != null) _buildReplyInputBar(style),
          Row(
            children: [
              if (style.allowAttachment) IconButton(icon: Icon(Icons.attach_file, color: Colors.grey[600]), onPressed: () => _adhook.pickAndUploadFile()),
              if (style.allowLocationSharing) IconButton(icon: Icon(Icons.location_on_outlined, color: Colors.grey[600]), onPressed: _handleLocation),
              Expanded(
                child: _isRecording 
                  ? Row(children: [const Icon(Icons.mic, color: Colors.red, size: 16), const SizedBox(width: 8), Expanded(child: _buildWaveform())])
                  : TextField(controller: _controller, onChanged: _onTextChanged, style: style.applyFont(const TextStyle(fontSize: 14)), decoration: InputDecoration(hintText: 'Type a message...', hintStyle: style.applyFont(const TextStyle(fontSize: 14, color: Colors.grey)), border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(horizontal: 12)), onSubmitted: (_) => _handleSend()),
              ),
              if (style.allowVoiceRecording && _controller.text.isEmpty)
                GestureDetector(onLongPressStart: (_) => _startRecording(), onLongPressEnd: (_) => _stopRecording(), child: Padding(padding: const EdgeInsets.all(8.0), child: Icon(_isRecording ? Icons.mic : Icons.mic_none, color: _isRecording ? Colors.red : Colors.grey[600]))),
              if (_controller.text.isNotEmpty) IconButton(icon: Icon(Icons.send, color: style.primaryColor), onPressed: _handleSend),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildReplyInputBar(AdhookChatStyle style) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: style.brightness == Brightness.dark ? Colors.white10 : Colors.black.withOpacity(0.05), borderRadius: BorderRadius.circular(8), border: Border(left: BorderSide(color: style.primaryColor, width: 4))),
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
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: List.generate(15, (index) {
        final height = 4.0 + (normalizedAmp * 20.0 * math.Random().nextDouble());
        return Container(width: 3, height: height, margin: const EdgeInsets.symmetric(horizontal: 1), decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(2)));
      }));
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
      appBar: AppBar(backgroundColor: Colors.transparent, iconTheme: const IconThemeData(color: Colors.white)),
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
