enum AdhookSender { visitor, agent }

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

  factory AdhookMessage.fromJson(Map<String, dynamic> json) {
    // Determine message type
    final messageType = json['type'] ?? json['message_type'] ?? 'TEXT';

    // Normalize sender type
    final senderType = json['sender_type'] ?? '';
    final isVisitor = senderType == 'visitor' || senderType == 'USER';

    return AdhookMessage(
      id: (json['id'] ?? '').toString(),
      content: json['content'] ?? json['message_text'] ?? '',
      sender: isVisitor ? AdhookSender.visitor : AdhookSender.agent,
      senderName: json['sender_name'] ?? json['agent_name'] ?? (isVisitor ? 'User' : 'Agent'),
      conversationId: json['conversation_id'],
      contactId: json['contact_id'],
      mediaUrl: json['media_url'] ?? json['file_url'],
      mimeType: json['mime_type'] ?? json['file_name'],
      createdAt: json['created_at'] != null 
          ? DateTime.parse(json['created_at']) 
          : DateTime.now(),
      type: messageType,
      isRead: json['is_read'] ?? false,
      replyToId: json['reply_to_id']?.toString(),
      replyToContent: json['reply_to_content'],
      replyToSender: json['reply_to_sender'],
    );
  }
}
