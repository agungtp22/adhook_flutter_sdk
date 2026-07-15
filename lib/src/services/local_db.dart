import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/message.dart';

class AdhookLocalDb {
  static final AdhookLocalDb _instance = AdhookLocalDb._internal();
  factory AdhookLocalDb() => _instance;
  AdhookLocalDb._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDb();
    return _database!;
  }

  Future<Database> _initDb() async {
    String path = join(await getDatabasesPath(), 'adhook_chat.db');
    return await openDatabase(
      path,
      version: 2, // Upgraded version for schema migration
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages(
            id TEXT PRIMARY KEY,
            conversation_id INTEGER,
            contact_id INTEGER,
            sender_type TEXT,
            message_type TEXT,
            message_text TEXT,
            media_url TEXT,
            mime_type TEXT,
            is_read INTEGER,
            reply_to_id TEXT,
            reply_to_content TEXT,
            reply_to_sender TEXT,
            created_at TEXT
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // Drop and recreate table for TEXT ID support
          await db.execute('DROP TABLE IF EXISTS messages');
          await db.execute('''
            CREATE TABLE messages(
              id TEXT PRIMARY KEY,
              conversation_id INTEGER,
              contact_id INTEGER,
              sender_type TEXT,
              message_type TEXT,
              message_text TEXT,
              media_url TEXT,
              mime_type TEXT,
              is_read INTEGER,
              reply_to_id TEXT,
              reply_to_content TEXT,
              reply_to_sender TEXT,
              created_at TEXT
            )
          ''');
        }
      },
    );
  }

  Future<void> saveMessage(AdhookMessage msg) async {
    final db = await database;
    await db.insert(
      'messages',
      {
        'id': msg.id,
        'conversation_id': msg.conversationId,
        'contact_id': msg.contactId,
        'sender_type': msg.sender == AdhookSender.visitor ? 'visitor' : 'agent',
        'message_type': msg.type,
        'message_text': msg.content,
        'media_url': msg.mediaUrl,
        'mime_type': msg.mimeType,
        'is_read': msg.isRead ? 1 : 0,
        'reply_to_id': msg.replyToId,
        'reply_to_content': msg.replyToContent,
        'reply_to_sender': msg.replyToSender,
        'created_at': msg.createdAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<AdhookMessage>> getMessages() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('messages', orderBy: 'created_at ASC');

    return List.generate(maps.length, (i) {
      return AdhookMessage(
        id: maps[i]['id']?.toString() ?? '',
        conversationId: maps[i]['conversation_id'],
        contactId: maps[i]['contact_id'],
        sender: maps[i]['sender_type'] == 'visitor' ? AdhookSender.visitor : AdhookSender.agent,
        type: maps[i]['message_type'] ?? 'TEXT',
        content: maps[i]['message_text'] ?? '',
        mediaUrl: maps[i]['media_url'],
        mimeType: maps[i]['mime_type'],
        isRead: maps[i]['is_read'] == 1,
        replyToId: maps[i]['reply_to_id']?.toString(),
        replyToContent: maps[i]['reply_to_content'],
        replyToSender: maps[i]['reply_to_sender'],
        createdAt: DateTime.parse(maps[i]['created_at']),
      );
    });
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.delete('messages');
  }
}
