import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../config/ai_config.dart';
import '../../services/api_client.dart';
import '../../state/session_scope.dart';
import 'package:legalserviceapp/widgets/customapp_bar.dart';
import 'package:legalserviceapp/constants/colors.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

// --- UI Constants --- (Added for easier theme management)
const Color primaryColor = AppColors.buttonColor; // Deep Purple variant
const Color accentColor = Color(0xFF009688); // Teal accent
const Color lightBackgroundColor = Color(0xFFF5F5F5); // Lighter grey background
const Color cardBackgroundColor = Colors.white;
const double defaultPadding = 16.0;
const double defaultBorderRadius = 12.0;

class DocumentReviewAI extends StatefulWidget {
  const DocumentReviewAI({super.key});

  @override
  DocumentReviewAIState createState() => DocumentReviewAIState();
}

class DocumentReviewAIState extends State<DocumentReviewAI> {
  String extractedText = '';
  bool isLoading = false;
  String aiFeedback = '';
  String fileName = '';
  List<int>? _selectedPdfBytes;

  Future<void> pickFile() async {
    if (isLoading) return;
    setState(() => isLoading = true);
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
        throw const FormatException('Choose a non-empty PDF no larger than 10 MiB.');
      }
      if (bytes.length < 5 ||
          bytes[0] != 0x25 ||
          bytes[1] != 0x50 ||
          bytes[2] != 0x44 ||
          bytes[3] != 0x46 ||
          bytes[4] != 0x2d) {
        throw const FormatException('The selected file does not have a valid PDF header.');
      }

      var preview = '';
      try {
        final document = PdfDocument(inputBytes: bytes);
        try {
          preview = PdfTextExtractor(document).extractText().trim();
        } finally {
          document.dispose();
        }
      } catch (_) {
        // Scanned or encrypted PDFs may not expose local text; the AI service
        // still receives the original PDF if the user explicitly consents.
      }
      if (preview.isEmpty) {
        preview = 'No selectable text was extracted on this device. The PDF can still be submitted for AI review.';
      }
      if (!mounted) return;
      setState(() {
        fileName = picked.name;
        _selectedPdfBytes = bytes;
        extractedText = preview;
        aiFeedback = '';
      });
    } catch (error) {
      _showErrorSnackbar('Could not read the selected PDF: $error');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<bool> _requestDocumentConsent() async {
    var consented = false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Consent to AI document review'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'To review this PDF, it will be uploaded to private Supabase Storage and sent to the configured AI provider (Google Gemini). The server attempts to delete the temporary Storage copy after processing. Do not submit documents unless you are authorized to share them.',
                  style: GoogleFonts.poppins(fontSize: 13, height: 1.45),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: consented,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    'I consent to this external AI processing.',
                    style: GoogleFonts.poppins(fontSize: 13),
                  ),
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
    return result == true;
  }

  Future<void> analyzeDocument() async {
    final pdfBytes = _selectedPdfBytes;
    if (pdfBytes == null || pdfBytes.isEmpty) {
      _showErrorSnackbar('Select a PDF before starting AI review.');
      return;
    }
    if (!await _requestDocumentConsent() || !mounted) return;

    final repository = SessionScope.read(context).repository;
    setState(() {
      isLoading = true;
      aiFeedback = '';
    });

    String? objectPath;
    var cleanupRequired = false;
    try {
      objectPath = await repository.uploadLegalDocumentPdf(pdfBytes);
      cleanupRequired = true;
      final result = await repository.analyzeLegalDocument(objectPath);
      aiFeedback = result['analysis'] as String;
      // The Edge Function already attempts deletion before returning. Retry
      // from the client only when it reports cleanup trouble.
      cleanupRequired = result['cleanupRequired'] == true;
    } catch (error) {
      _showErrorSnackbar('AI analysis failed: $error');
    } finally {
      if (objectPath != null && cleanupRequired) {
        try {
          await repository.deleteTemporaryLegalDocument(objectPath);
          cleanupRequired = false;
        } on ApiException catch (error) {
          cleanupRequired = !error.isNotFound;
        } catch (_) {
          cleanupRequired = true;
        }
      }
      if (mounted) {
        setState(() => isLoading = false);
        if (cleanupRequired) {
          _showErrorSnackbar('AI review may have completed, but temporary document cleanup could not be confirmed. Please contact support.');
        }
      }
    }
  }

  // Helper methods (Unchanged logic, potentially updated style)
  void _showErrorSnackbar(String message) {
    if (!mounted) return; // Check if the widget is still in the tree
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: GoogleFonts.poppins()),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating, // More modern look
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
        margin: const EdgeInsets.all(defaultPadding),
      ),
    );
  }

  // --- Widget Building Methods (UI Focused Enhancements) ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(defaultPadding), // Consistent padding
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [

              CustomAppBar(text: 'Document Review AI', text1: ''),
              SizedBox(height: 10,),
              _buildUploadCard(),
              const SizedBox(height: defaultPadding * 1.5), // Increased spacing
              Expanded(child: _buildContentTabs()),
            ],
          ),
        ),
      ),
      floatingActionButton: _buildFloatingActionButton(),
    );
  }


  Card _buildUploadCard() {
    return Card(
      elevation: 3.0, // Slightly softer elevation
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(defaultBorderRadius)),
      color: cardBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.all(defaultPadding * 1.25), // More internal padding
        child: Column(
          children: [
            // Enhanced Icon
            CircleAvatar(
              radius: 30,
              backgroundColor: primaryColor.withAlpha((0.2 * 255).toInt()),
              child: Icon(Icons.cloud_upload_outlined, size: 32, color: primaryColor),
            ),
            const SizedBox(height: defaultPadding),
            Text(
              "Upload Document for Analysis",
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: defaultPadding / 2),
            Text(
              "Private PDF review · up to 10 MiB",
              style: GoogleFonts.poppins(
                fontSize: 14,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: defaultPadding * 1.5),

            if (_selectedPdfBytes == null)
              _buildSelectFileButton()
            else
              _buildFileInfo(),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectFileButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: isLoading ? null : pickFile, // Disable while loading
        icon: const Icon(Icons.upload_file_rounded, size: 20),
        label: Text(
          "Select File",
          style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: accentColor, // Use accent color
          foregroundColor: Colors.white, // Text color
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(defaultBorderRadius),
          ),
          padding: const EdgeInsets.symmetric(vertical: defaultPadding * 0.9), // Adjusted padding
          elevation: 2.0,
        ),
      ),
    );
  }

  Widget _buildFileInfo() {
    return Column(
      children: [
        ListTile(
          leading: Icon(Icons.insert_drive_file_rounded, color: primaryColor),
          title: Text(
            fileName,
            style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          subtitle: Text(
            "Ready; private upload begins only after consent.",
            style: GoogleFonts.poppins(color: Colors.grey[600]),
          ),
          // Add a trailing button to change the file
          trailing: IconButton(
            icon: Icon(Icons.change_circle_outlined, color: Colors.grey[500]),
            tooltip: "Select a different file",
            onPressed: isLoading ? null : pickFile, // Allow changing file if not busy
          ),
          contentPadding: EdgeInsets.zero, // Remove default padding
        ),
      ],
    );
  }


  Widget _buildContentTabs() {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(4.0), // Padding around the tabs
            decoration: BoxDecoration(
              color: Colors.grey[200], // Background for the tab bar area
              borderRadius: BorderRadius.circular(defaultBorderRadius),
            ),
            child: TabBar(
              labelColor: Colors.white, // Selected text color
              unselectedLabelColor: primaryColor, // Unselected text color
              indicatorSize: TabBarIndicatorSize.tab, // Indicator fills the tab
              indicator: BoxDecoration(
                borderRadius: BorderRadius.circular(defaultBorderRadius - 4), // Slightly smaller radius
                color: primaryColor, // Indicator color
              ),
              tabs: [
                _buildTab("Document Text", Icons.article_outlined),
                _buildTab("AI Analysis", Icons.auto_awesome_outlined), // Use outlined icons
              ],
            ),
          ),
          const SizedBox(height: defaultPadding), // Space between tabs and content
          Expanded(
            child: TabBarView(
              children: [
                _buildDocumentTextTab(),
                _buildAnalysisTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Helper for creating styled tabs
  Widget _buildTab(String text, IconData icon) {
    return Tab(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(
            text,
            style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentTextTab() {
    // Show loading indicator specific to text extraction if needed,
    // but global isLoading often covers this.
    if (isLoading && extractedText.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: primaryColor));
    }

    return Card( // Wrap content in a card for consistency
        elevation: 1.0,
        margin: EdgeInsets.zero, // Let TabBarView handle spacing if needed
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(defaultBorderRadius)),
        color: cardBackgroundColor,
        child: extractedText.isNotEmpty
            ? Padding(
          padding: const EdgeInsets.all(defaultPadding),
          child: SingleChildScrollView(
            child: SelectableText( // Good for copying text
              extractedText,
              style: GoogleFonts.robotoSlab(fontSize: 15, height: 1.5, color: Colors.black87), // Use a readable slab serif
            ),
          ),
        )
            : _buildEmptyState(
          icon: Icons.description_outlined,
          message: "Upload a document to view its text here.",
          buttonText: "Select File",
          onButtonPressed: pickFile,
        )
    );
  }


  Widget _buildAnalysisTab() {
    // Show loading indicator specifically when AI analysis is running
    if (isLoading && aiFeedback.isEmpty && _selectedPdfBytes != null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: primaryColor),
            SizedBox(height: defaultPadding),
            Text("AI is analyzing...", style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }


    return Card( // Wrap content in a card
        elevation: 1.0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(defaultBorderRadius)),
        color: cardBackgroundColor,
        child: aiFeedback.isNotEmpty
            ? Padding(
          padding: const EdgeInsets.all(defaultPadding),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AiConfig.advisoryNotice,
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    color: Colors.deepOrange,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  aiFeedback,
                  style: GoogleFonts.poppins(fontSize: 15, height: 1.5, color: Colors.black87),
                ),
              ],
            ),
          ),
        )
            : _buildEmptyState(
          icon: Icons.auto_awesome_motion_outlined, // Engaging icon
          message: _selectedPdfBytes == null
              ? "Upload a PDF first."
              : "Run analysis to see AI feedback.",
          buttonText: "Analyze Document",
          onButtonPressed: (_selectedPdfBytes != null && !isLoading) ? analyzeDocument : null,
        )
    );
  }


  Widget _buildEmptyState({
    required IconData icon,
    required String message,
    String? buttonText, // Optional button
    VoidCallback? onButtonPressed, // Action for the button
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(defaultPadding * 2), // More padding for empty state
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center, // Center horizontally
          children: [
            Icon(icon, size: 64, color: Colors.grey[400]), // Larger icon
            const SizedBox(height: defaultPadding),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                fontSize: 16,
                color: Colors.grey[600], // Slightly darker grey
              ),
            ),
            if (buttonText != null) ...[
              const SizedBox(height: defaultPadding * 1.5),
              ElevatedButton(
                onPressed: onButtonPressed, // Use the provided callback
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor, // Use accent color
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(defaultBorderRadius),
                  ),
                  padding: const EdgeInsets.symmetric(
                      vertical: defaultPadding * 0.8, horizontal: defaultPadding * 1.5),
                ),
                child: Text(
                  buttonText,
                  style: GoogleFonts.poppins(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget? _buildFloatingActionButton() {
    if (_selectedPdfBytes != null && aiFeedback.isEmpty && !isLoading) {
      return FloatingActionButton.extended(
        onPressed: analyzeDocument,
        backgroundColor: accentColor, // Use accent color
        foregroundColor: Colors.white,
        icon: const Icon(Icons.auto_awesome_rounded), // Rounded icon
        label: Text(
          "Analyze Now",
          style: GoogleFonts.poppins(
              fontWeight: FontWeight.w600), // Bolder text
        ),
        elevation: 4.0, // Standard elevation
      );
    }
    // Don't show FAB otherwise
    return null;
  }
}