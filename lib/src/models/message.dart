enum AdhookSender { visitor, agent }

class AdhookMessage {
  final int id;
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
  final int? replyToId;
  final String? replyToContent;
  final String? replyToSender;

  AdhookMessage({
    required this.id,
    required this.content,
    required this.sender,
    required this.createdAt,
    this.type = 'text',
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
    return AdhookMessage(
      id: json['id'] ?? 0,
      content: json['message_text'] ?? '',
      sender: json['sender_type'] == 'visitor' ? AdhookSender.visitor : AdhookSender.agent,
      senderName: json['sender_name'],
      conversationId: json['conversation_id'],
      contactId: json['contact_id'],
      mediaUrl: json['media_url'],
      mimeType: json['mime_type'],
      createdAt: json['created_at'] != null 
          ? DateTime.parse(json['created_at']) 
          : DateTime.now(),
      type: json['message_type'] ?? 'text',
      isRead: json['is_read'] ?? false,
      replyToId: json['reply_to_id'],
      replyToContent: json['reply_to_content'],
      replyToSender: json['reply_to_sender'],
    );
  }
}
