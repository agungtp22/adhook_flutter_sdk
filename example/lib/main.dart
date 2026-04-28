import 'package:flutter/material.dart';
import 'package:adhook_flutter_sdk/adhook_flutter_sdk.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Adhook SDK with AdMedika settings
  await AdhookChat.init(
    apiKey: '',
    baseUrl: '',
    widgetKey: '',
    name: '',
    email: '',
    debugMode: true,
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Adhook SDK Pro Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFED1C24)),
        useMaterial3: true,
        fontFamily: 'Inter', // Example of custom font
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AdMedika Mobile')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.medical_services,
              size: 80,
              color: Color(0xFFED1C24),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              icon: const Icon(Icons.support_agent),
              label: const Text('Start Professional Chat'),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const ChatScreen()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // 1. Fully Customized Adhook Style
    final myStyle = AdhookChatStyle(
      primaryColor: const Color(0xFFED1C24), // AdMedika Red
      visitorBubbleColor: const Color(
        0xFFED1C24,
      ), // Warna Bubble Pengirim (Kirim)
      agentBubbleColor: const Color(0xFFF1F1F1), // Warna Bubble Agent (Terima)
      fontFamily: 'Inter',
      bubbleRadius: 16.0,

      // Feature Flags - Toggle as needed
      allowAttachment: true,
      allowVoiceRecording: true,
      allowLocationSharing: true,

      showAppBar: true,
      visitorTextStyle: const TextStyle(fontSize: 15, color: Colors.white),
      agentTextStyle: const TextStyle(fontSize: 15, color: Colors.black87),
    );

    return AdhookChatWindow(
      title: 'AdMedika Helpdesk',
      style: myStyle,
      // Gunakan IconButton agar tetap bisa back sambil menampilkan avatar
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => Navigator.pop(context),
      ),
    );
  }
}
