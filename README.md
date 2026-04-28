# Adhook Flutter SDK

Build premium real-time communication experiences in your Flutter apps with AdMedika Adhook.

[![pub package](https://img.shields.io/badge/pub-v0.0.1-blue.svg)](https://pub.dev/packages/adhook_flutter_sdk)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## Table of Contents
- [Features](#features)
- [Installation](#installation)
- [Android Setup](#android-setup)
- [iOS Setup](#ios-setup)
- [Usage](#usage)
- [Customization](#customization)
- [Persistence](#persistence)
- [Troubleshooting](#troubleshooting)

---

## Features

- **Real-time & Reliable**: Powered by WebSockets with automatic exponential backoff reconnection.
- **Offline First**: Instant message loading using local SQLite persistence.
- **Media Rich**: Support for high-quality voice notes, image sharing (with zoom), and documents.
- **Location Services**: Integrated GPS coordinate sharing.
- **Branding Friendly**: Fully customizable UI components to match AdMedika's brand identity.
- **Agent Feedback**: Built-in 5-star rating and comment system.

---

## Installation

Add `adhook_flutter_sdk` to your `pubspec.yaml`:

```yaml
dependencies:
  adhook_flutter_sdk: ^0.0.1
```

Or for local development:

```yaml
dependencies:
  adhook_flutter_sdk:
    path: path/to/sdk
```

---

## Android Setup

1. Add the following permissions to your `AndroidManifest.xml`:

```xml
<!-- Internet access -->
<uses-permission android:name="android.permission.INTERNET" />
<!-- For Voice Messages -->
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<!-- For Location Sharing -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

2. (Optional) If you target Android 10+, add `android:requestLegacyExternalStorage="true"` to your `<application>` tag for file picking compatibility.

---

## iOS Setup

Add the following keys to your `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Allow access to microphone for sending voice notes in chat.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Allow access to location to share your current position with our agents.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Allow access to photo library to send documents and images.</string>
<key>NSCameraUsageDescription</key>
<string>Allow access to camera to take photos and send them in chat.</string>
```

---

## Usage

### 1. Initialize Adhook
Initialize the SDK at the start of your application.

```dart
import 'package:adhook_flutter_sdk/adhook_flutter_sdk.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AdhookChat.init(
    apiKey: 'your_api_key',
    baseUrl: 'https://apim.admedika.co.id/adhook',
    widgetKey: 'your_widget_key',
    debugMode: true,
  );

  runApp(const MyApp());
}
```

### 2. Open Chat Window
Simply navigate to `AdhookChatWindow`.

```dart
ElevatedButton(
  onPressed: () {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AdhookChatWindow(
          title: 'AdMedika Support',
          style: AdhookChatStyle.admedika(), // Preset AdMedika style
        ),
      ),
    );
  },
  child: const Text('Start Chat'),
)
```

---

## Customization

### The `AdhookChatStyle` Class

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `primaryColor` | `Color` | `Color(0xFFED1C24)` | Primary color for UI elements |
| `visitorBubbleColor` | `Color` | `primaryColor` | Background for user messages |
| `agentBubbleColor` | `Color` | `Color(0xFFF1F1F1)` | Background for agent messages |
| `fontFamily` | `String` | `'Inter'` | Custom font family |
| `brightness` | `Brightness` | `Brightness.light` | Dark/Light mode toggle |
| `allowAttachment` | `bool` | `true` | Toggle file sharing |

---

## Persistence

The SDK implements **Offline Persistence** using `sqflite`.
- **Instant Load**: Previous messages are loaded immediately from local storage while the socket connects.
- **Auto-Sync**: Every incoming message and history fetch is automatically persisted.
- **Storage**: On Web, storage falls back to memory for stability.

---

## Troubleshooting

- **Error: 401 Unauthorized**: The `widgetKey` provided does not exist in the database.
- **Connection Stuck**: Verify that `wss://` is not blocked by your network firewall.
- **No Back Button**: If you provide a `leading` widget to `AdhookChatWindow`, it will override the default back button. Ensure you handle navigation in your custom `leading` widget.

---

## License

MIT License. Copyright © 2026 AdMedika.
