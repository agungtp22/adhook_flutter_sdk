import 'package:flutter/material.dart';

class AdhookChatStyle {
  final Color primaryColor;
  final Color backgroundColor;
  final Color visitorBubbleColor;
  final Color agentBubbleColor;
  final TextStyle visitorTextStyle;
  final TextStyle agentTextStyle;
  final TextStyle? appBarTitleStyle;
  final double bubbleRadius;
  final double buttonRadius;
  final EdgeInsets bubblePadding;
  final bool showAppBar;
  final String? fontFamily;
  
  // Fitur Config
  final bool allowAttachment;
  final bool allowVoiceRecording;
  final bool allowLocationSharing;

  // Dark Mode Support
  final Brightness brightness;

  const AdhookChatStyle({
    this.primaryColor = const Color(0xFFED1C24),
    this.backgroundColor = const Color(0xFFF8F9FA),
    this.visitorBubbleColor = const Color(0xFFED1C24),
    this.agentBubbleColor = Colors.white,
    this.visitorTextStyle = const TextStyle(color: Colors.white, fontSize: 14),
    this.agentTextStyle = const TextStyle(color: Colors.black87, fontSize: 14),
    this.appBarTitleStyle = const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
    this.bubbleRadius = 12.0,
    this.buttonRadius = 8.0,
    this.bubblePadding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    this.showAppBar = true,
    this.fontFamily,
    this.allowAttachment = true,
    this.allowVoiceRecording = true,
    this.allowLocationSharing = true,
    this.brightness = Brightness.light,
  });

  /// Factory for dark mode preset
  factory AdhookChatStyle.dark({
    Color primaryColor = const Color(0xFFED1C24),
    String? fontFamily,
  }) {
    return AdhookChatStyle(
      primaryColor: primaryColor,
      backgroundColor: const Color(0xFF121212),
      visitorBubbleColor: primaryColor,
      agentBubbleColor: const Color(0xFF1E1E1E),
      visitorTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
      agentTextStyle: const TextStyle(color: Colors.white70, fontSize: 14),
      appBarTitleStyle: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
      brightness: Brightness.dark,
      fontFamily: fontFamily,
    );
  }

  TextStyle applyFont(TextStyle style) {
    if (fontFamily == null) return style;
    return style.copyWith(fontFamily: fontFamily);
  }
}
