import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../config/ai_config.dart';
import '../../state/session_scope.dart';

class LegalChatScreen extends StatefulWidget {
  const LegalChatScreen({super.key});

  @override
  LegalChatScreenState createState() => LegalChatScreenState();
}

class LegalChatScreenState extends State<LegalChatScreen> {
  final TextEditingController _controller = TextEditingController();
  List<Map<String, String>> messages = [];
  bool isLoading = false;
  bool _aiConsentGranted = false;

  Future<bool> _requestAiConsent() async {
    if (_aiConsentGranted) return true;
    var consented = false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('External AI processing'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Your legal question will be sent to Google Gemini for an AI-generated response. Avoid including names, account numbers, or confidential details. The response is general information, not legal advice.',
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: consented,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('I consent to external AI processing.'),
                  onChanged: (value) =>
                      setDialogState(() => consented = value ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: consented
                  ? () => Navigator.of(dialogContext).pop(true)
                  : null,
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
    _aiConsentGranted = result == true;
    return _aiConsentGranted;
  }

  Future<void> sendMessage() async {
    final userMessage = _controller.text.trim();
    if (userMessage.isEmpty || isLoading) return;
    if (!await _requestAiConsent() || !mounted) return;

    setState(() {
      messages.add({'role': 'user', 'text': userMessage});
      isLoading = true;
    });
    _controller.clear();

    final botResponse = await fetchLegalResponse(userMessage);
    if (!mounted) return;
    setState(() {
      messages.add({
        'role': 'bot',
        'text': botResponse ?? AiConfig.unavailableMessage,
      });
      isLoading = false;
    });
  }

  Future<String?> fetchLegalResponse(String prompt) async {
    try {
      return await SessionScope.read(context)
          .repository
          .askLegalAssistant(prompt);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Legal AI Chatbot",
            style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w600,color: Colors.white)),
        backgroundColor: Colors.black87,
        centerTitle: true,
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              'AI responses are general information, not legal advice. Verify important decisions with a qualified lawyer.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.all(10),
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final msg = messages[index];
                bool isUser = msg["role"] == "user";
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    padding: EdgeInsets.all(12),
                    margin: EdgeInsets.symmetric(vertical: 6),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
                    decoration: BoxDecoration(
                      color: isUser ? Colors.amber : Colors.grey[800],
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(isUser ? 16 : 0),
                        topRight: Radius.circular(isUser ? 0 : 16),
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(16),
                      ),
                    ),
                    child: Text(
                      msg["text"]!,
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (isLoading)
            Padding(
              padding: EdgeInsets.all(8.0),
              child: CircularProgressIndicator(color: Colors.amber),
            ),
          _buildMessageInput(),
        ],
      ),
    );
  }

  Widget _buildMessageInput() {
    return Container(
      padding: EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black87,
        border: Border(
          top: BorderSide(color: Colors.grey.shade700, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              style: GoogleFonts.poppins(fontSize: 16, color: Colors.white),
              decoration: InputDecoration(
                hintText: "Ask a legal question...",
                hintStyle: GoogleFonts.poppins(color: Colors.white54),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                filled: true,
                fillColor: Colors.grey[800],
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide(color: Colors.amber),
                ),
              ),
            ),
          ),
          SizedBox(width: 10),
          InkWell(
            onTap: sendMessage,
            child: CircleAvatar(
              backgroundColor: Colors.amber,
              radius: 25,
              child: Icon(Icons.send, color: Colors.black),
            ),
          ),
        ],
      ),
    );
  }
}
