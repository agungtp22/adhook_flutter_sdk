enum AdhookSender { visitor, agent, system }

class AdhookMessage {
  final String id;
  final String content;
  final AdhookSender sender;
  final DateTime createdAt;
  final String type;
  final String? senderName;
  final int? conversationId;
  final int? contactId;
  final String? mediaUrl;
  final String? mimeType;
  bool isRead;
  
  // Fields for Reply/Quote
  final String? replyToId;
  final String? replyToContent;
  final String? replyToSender;

  AdhookMessage({
    required this.id,
    required this.content,
    required this.sender,
    required this.createdAt,
    this.type = 'TEXT',
    this.senderName,
    this.conversationId,
    this.contactId,
    this.mediaUrl,
    this.mimeType,
    this.isRead = false,
    this.replyToId,
    this.replyToContent,
    this.replyToSender,
  });

  static DateTime parseCreatedAt(dynamic raw) {
    if (raw == null) return DateTime.now();
    if (raw is DateTime) return raw;
    final str = raw.toString().trim();
    if (str.isEmpty) return DateTime.now();

    try {
      String normalized = str.replaceAll(' ', 'T');
      // Strip trailing timezone offsets (Z or +07:00 / -05:00) so we parse exact wall-clock time
      normalized = normalized.replaceAll(RegExp(r'(Z|[+-]\d{2}:?\d{2})$'), '');
      return DateTime.parse(normalized);
    } catch (_) {
      return DateTime.now();
    }
  }

  factory AdhookMessage.fromJson(Map<String, dynamic> json) {
    // Determine message type
    final messageType = json['type'] ?? json['message_type'] ?? 'TEXT';

    // Normalize sender type
    final senderType = (json['sender_type'] ?? '').toString().toLowerCase();
    final isVisitor = senderType == 'visitor' || senderType == 'user';
    final isSystem = senderType == 'system' || messageType.toString().toLowerCase() == 'system';

    final AdhookSender senderEnum = isSystem
        ? AdhookSender.system
        : (isVisitor ? AdhookSender.visitor : AdhookSender.agent);

    return AdhookMessage(
      id: (json['id'] ?? '').toString(),
      content: json['content'] ?? json['message_text'] ?? '',
      sender: senderEnum,
      senderName: json['sender_name'] ?? json['agent_name'] ?? (isSystem ? 'System' : (isVisitor ? 'User' : 'Agent')),
      conversationId: json['conversation_id'],
      contactId: json['contact_id'],
      mediaUrl: json['media_url'] ?? json['file_url'],
      mimeType: json['mime_type'] ?? json['file_name'],
      createdAt: parseCreatedAt(json['created_at']),
      type: messageType,
      isRead: json['is_read'] ?? false,
      replyToId: json['reply_to_id']?.toString(),
      replyToContent: json['reply_to_content'],
      replyToSender: json['reply_to_sender'],
    );
  }
}
