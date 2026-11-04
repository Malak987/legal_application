import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:syncfusion_flutter_sliders/sliders.dart';
import 'package:flutter_vector_icons/flutter_vector_icons.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../constants/colors.dart';
import '../../config/ai_config.dart';
import '../../state/session_scope.dart';

// --- UI Constants --- (Optional, but good practice)
 Color primaryTextColor = AppColors.buttonColor; // blueGrey[800]
const Color secondaryTextColor = Color(0xFF546E7A); // blueGrey[600]
const Color accentColor = Color(0xFFFFC107); // amber[400]
const Color appBarColor = AppColors.buttonColor; // blueGrey[900]
const double defaultPadding = 20.0;
const double defaultRadius = 12.0;

class CasePredictionTool extends StatefulWidget {
  const CasePredictionTool({super.key});

  @override
  CasePredictionToolState createState() => CasePredictionToolState();
}

class CasePredictionToolState extends State<CasePredictionTool>
    with SingleTickerProviderStateMixin {
  // Form state
  final _formKey = GlobalKey<FormState>();
  String _caseDescription = '';
  String _jurisdiction = 'Federal'; // Default value
  String _caseType = 'Civil'; // Default value
  double _similarPrecedentWeight = 50;
  double _legalArgumentStrength = 50;
  double _evidenceQuality = 50;

  // Prediction state
  double _predictionScore = 0;
  String _predictionAnalysis = '';
  bool _isLoading = false;
  bool _hasResult = false;
  late AnimationController _animationController;
  late Animation<double> _scoreAnimation;

  // Options (Ensure defaults are included)
  final List<String> _jurisdictions = [
    'Federal',
    'State',
    'International',
    'Supreme Court',
    'Local', // Added example
    'Tribal' // Added example
  ];

  final List<String> _caseTypes = [
    'Civil',
    'Criminal',
    'Contract',
    'Family',
    'Employment',
    'Intellectual Property',
    'Personal Injury', // Added example
    'Real Estate' // Added example
  ];

  @override
  void initState() {
    super.initState();
    // Ensure default values are valid options
    if (!_jurisdictions.contains(_jurisdiction)) {
      _jurisdiction = _jurisdictions.first;
    }
    if (!_caseTypes.contains(_caseType)) {
      _caseType = _caseTypes.first;
    }

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    // Initialize animation with a default range, will be updated on result
    _scoreAnimation = Tween<double>(begin: 0, end: 0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeOutQuart,
      ),
    );
    _animationController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _predictCaseOutcome() async {
    _formKey.currentState?.save();
    if (!_formKey.currentState!.validate()) {
      _showErrorSnackbar('Please fill in all required fields.');
      return;
    }

    setState(() {
      _isLoading = true;
      _hasResult = false;
      _predictionAnalysis = '';
      _predictionScore = 0;
    });

    try {
      final generatedText = await _fetchPrediction();
      final parsedResult = _parseGeneratedText(generatedText);
      if (!mounted) return;
      setState(() {
        _predictionScore = parsedResult['score'] as double;
        _predictionAnalysis = parsedResult['analysis'] as String;
        _hasResult = true;
      });
      _scoreAnimation = Tween<double>(begin: 0, end: _predictionScore).animate(
        CurvedAnimation(
          parent: _animationController,
          curve: Curves.easeOutQuart,
        ),
      );
      _animationController
        ..reset()
        ..forward();
    } catch (error) {
      _showErrorSnackbar('Prediction failed: $error');
      if (mounted) setState(() => _hasResult = false);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Parses the response's illustrative score and its supporting analysis.
  /// Invalid model output is an error, never a fabricated zero-score result.
  Map<String, dynamic> _parseGeneratedText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('The AI returned an empty response.');
    }
    final lines = trimmed.split('\n');
    final score = double.tryParse(lines.first.trim());
    if (score == null || !score.isFinite || score < 0 || score > 100) {
      throw const FormatException('The AI response did not contain a valid 0-100 illustrative score.');
    }
    final analysis = lines.skip(1).join('\n').trim();
    if (analysis.isEmpty) {
      throw const FormatException('The AI response did not contain an analysis.');
    }
    return <String, dynamic>{'score': score, 'analysis': analysis};
  }

  Future<String> _fetchPrediction() =>
      SessionScope.read(context).repository.predictCaseOutcome(
        jurisdiction: _jurisdiction,
        caseType: _caseType,
        description: _caseDescription,
        precedentWeight: _similarPrecedentWeight.round(),
        argumentStrength: _legalArgumentStrength.round(),
        evidenceQuality: _evidenceQuality.round(),
      );
  void _showErrorSnackbar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: GoogleFonts.poppins()),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
        margin: const EdgeInsets.all(defaultPadding),
      ),
    );
  }

  Color _getScoreColor(double score) {
    if (score >= 70) return Colors.green[600]!;
    if (score >= 40) return Colors.orange[600]!;
    return Colors.red[600]!;
  }

  String _getScoreInterpretation(double score) {
    if (score >= 80) return 'AI assessment · very favorable';
    if (score >= 60) return 'AI assessment · favorable';
    if (score >= 40) return 'AI assessment · mixed';
    if (score >= 20) return 'AI assessment · unfavorable';
    return 'AI assessment · very unfavorable';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: _buildAppBar(),
      body: GestureDetector( // Allow dismissing keyboard on tap outside fields
        onTap: () => FocusScope.of(context).unfocus(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(defaultPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildInfoCard(),
              const SizedBox(height: defaultPadding * 1.2),
              Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildCaseDescriptionField(),
                    const SizedBox(height: defaultPadding),
                    Row( // Place dropdowns side-by-side on wider screens if desired
                      children: [
                        Expanded(child: _buildJurisdictionDropdown()),
                        const SizedBox(width: defaultPadding * 0.75),
                        Expanded(child: _buildCaseTypeDropdown()),
                      ],
                    ),
                    // _buildJurisdictionDropdown(), // Uncomment these if you prefer vertical layout
                    // const SizedBox(height: defaultPadding),
                    // _buildCaseTypeDropdown(),
                    const SizedBox(height: defaultPadding * 1.5), // More space before sliders
                    _buildFactorSlider(
                      label: "Similar Precedent Weight",
                      value: _similarPrecedentWeight,
                      icon: Feather.book_open, // Changed icon
                      onChanged: (value) => setState(() => _similarPrecedentWeight = value),
                    ),
                    const SizedBox(height: defaultPadding * 0.8), // Slightly less space between sliders
                    _buildFactorSlider(
                      label: "Legal Argument Strength",
                      value: _legalArgumentStrength,
                      icon: Feather.edit, // Changed icon
                      onChanged: (value) => setState(() => _legalArgumentStrength = value),
                    ),
                    const SizedBox(height: defaultPadding * 0.8),
                    _buildFactorSlider(
                      label: "Evidence Quality",
                      value: _evidenceQuality,
                      icon: Feather.file_text,
                      onChanged: (value) => setState(() => _evidenceQuality = value),
                    ),
                    const SizedBox(height: defaultPadding * 1.8), // More space before button
                    _buildPredictButton(),
                  ],
                ),
              ),
              // Conditional Loading and Results
              if (_isLoading) ...[
                const SizedBox(height: defaultPadding * 1.5),
                _buildLoadingIndicator(),
              ],
              // Use AnimatedOpacity for smoother appearance/disappearance of results
              AnimatedOpacity(
                opacity: _hasResult && !_isLoading ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 500),
                child: _hasResult && !_isLoading ? _buildResultsSection() : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      title: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: "Case",
              style: GoogleFonts.poppins(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            TextSpan(
              text: "Predict",
              style: GoogleFonts.poppins(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color:Colors.orange
              ),
            ),
            TextSpan(
              text: " AI", // Space added for clarity
              style: GoogleFonts.poppins(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
      backgroundColor: appBarColor, // Use constant
      centerTitle: true,
      elevation: 0, // Keep flat look
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
      ),
      // --- CORRECTED actions placement ---
      actions: [
        IconButton(
          tooltip: "How it works", // Add tooltip
          icon: Icon(Feather.info, color: Colors.white.withAlpha((0.2 * 255).toInt())),
          onPressed: _showHowItWorksDialog,
        ),
        const SizedBox(width: 8), // Add some spacing
      ],
      // --- END OF CORRECTION ---
    );
  }

  Card _buildInfoCard() {
    return Card(
      elevation: 3, // Slightly reduced elevation
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(defaultRadius)),
      color: Colors.blueGrey[50], // Direct color
      child: Padding(
        padding: const EdgeInsets.all(defaultPadding * 0.9), // Slightly adjust padding
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Feather.activity, color: primaryTextColor), // Different Icon
                const SizedBox(width: 10),
                Text(
                  "Case Prediction Estimator", // Slightly different title
                  style: GoogleFonts.poppins(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: primaryTextColor, // Use constant
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              "Estimate potential case outcomes by providing details and factor weights. "
                  "The AI analyzes patterns and precedents. Results are indicative, not definitive.", // Refined text
              style: GoogleFonts.poppins(
                color: secondaryTextColor, // Use constant
                height: 1.45, // Adjust line height
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCaseDescriptionField() {
    return TextFormField(
      maxLines: 4, // Reduced lines slightly
      minLines: 3,
      decoration: InputDecoration(
        labelText: "Case Description *", // Indicate required
        labelStyle: GoogleFonts.poppins(color: secondaryTextColor),
        hintText: "Summarize facts, parties, key legal questions, desired outcome...",
        hintStyle: GoogleFonts.poppins(color: Colors.blueGrey[300], fontSize: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(defaultRadius),
          borderSide: BorderSide(color: Colors.blueGrey[200]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(defaultRadius),
          borderSide: BorderSide(color: Colors.blueGrey[200]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(defaultRadius),
          borderSide: BorderSide(color: primaryTextColor, width: 1.5), // Highlight focus
        ),
        prefixIcon: Padding( // Add padding to icon
          padding: const EdgeInsets.only(left: 12.0, right: 8.0),
          child: Icon(Feather.file_text, color: secondaryTextColor, size: 20),
        ),
        prefixIconConstraints: const BoxConstraints(minHeight: 48), // Ensure icon aligns
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12), // Adjust padding
      ),
      style: GoogleFonts.poppins(color: primaryTextColor, fontSize: 15),
      validator: (value) {
        if (value == null || value.trim().isEmpty) { // Use trim()
          return 'Please provide a case description';
        }
        if (value.trim().length < 20) { // Add min length example
          return 'Please provide a more detailed description (min 20 chars)';
        }
        return null;
      },
      onSaved: (value) => _caseDescription = value?.trim() ?? '', // Use trim() on save
    );
  }

  // Helper for Input Decor
  InputDecoration _dropdownDecoration(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      labelStyle: GoogleFonts.poppins(color: secondaryTextColor),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(defaultRadius),
        borderSide: BorderSide(color: Colors.blueGrey[200]!),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(defaultRadius),
        borderSide: BorderSide(color: Colors.blueGrey[200]!),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(defaultRadius),
        borderSide: BorderSide(color: primaryTextColor, width: 1.5),
      ),
      prefixIcon: Padding(
        padding: const EdgeInsets.only(left: 12.0, right: 8.0),
        child: Icon(icon, color: secondaryTextColor, size: 20),
      ),
      prefixIconConstraints: const BoxConstraints(minHeight: 48),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 0), // Adjust padding for dropdown
    );
  }

  Widget _buildJurisdictionDropdown() {
    return DropdownButtonFormField<String>(
      value: _jurisdiction,
      decoration: _dropdownDecoration("Jurisdiction", Feather.map_pin),
      isExpanded: true, // Allow text to fill width
      items: _jurisdictions.map((String value) {
        return DropdownMenuItem<String>(
          value: value,
          child: Padding( // Add padding inside item
            padding: const EdgeInsets.only(left: 8.0),
            child: Text(value, style: GoogleFonts.poppins(color: primaryTextColor), overflow: TextOverflow.ellipsis),
          ),
        );
      }).toList(),
      onChanged: (value) => setState(() => _jurisdiction = value!),
      validator: (value) => value == null ? 'Please select jurisdiction' : null, // Add validation
      onSaved: (value) => _jurisdiction = value ?? _jurisdictions.first,
    );
  }

  Widget _buildCaseTypeDropdown() {
    return DropdownButtonFormField<String>(
      value: _caseType,
      decoration: _dropdownDecoration("Case Type", Feather.briefcase),
      isExpanded: true,
      items: _caseTypes.map((String value) {
        return DropdownMenuItem<String>(
          value: value,
          child: Padding(
            padding: const EdgeInsets.only(left: 8.0),
            child: Text(value, style: GoogleFonts.poppins(color: primaryTextColor), overflow: TextOverflow.ellipsis),
          ),
        );
      }).toList(),
      onChanged: (value) => setState(() => _caseType = value!),
      validator: (value) => value == null ? 'Please select case type' : null,
      onSaved: (value) => _caseType = value ?? _caseTypes.first,
    );
  }

  Widget _buildFactorSlider({
    required String label,
    required double value,
    required IconData icon,
    required ValueChanged<double> onChanged, // Your function still expects double
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween, // Align label and value
          children: [
            Row( // Group icon and label
              children: [
                Icon(icon, size: 18, color: secondaryTextColor),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: GoogleFonts.poppins(
                      color: primaryTextColor,
                      fontWeight: FontWeight.w500,
                      fontSize: 15
                  ),
                ),
              ],
            ),
            Text( // Show current value
              '${value.round()}%',
              style: GoogleFonts.poppins(
                  color: primaryTextColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 15
              ),
            ),
          ],
        ),
        SfSlider(
          min: 0,
          max: 100,
          value: value, // value is double
          interval: 20,
          showTicks: true,
          showLabels: true,
          enableTooltip: true,
          activeColor: primaryTextColor,
          inactiveColor: Colors.blueGrey[100],
          labelFormatterCallback: (actualValue, formattedText) => '${actualValue.round()}',
          tooltipTextFormatterCallback: (actualValue, formattedText) => '${actualValue.round()}%',
          // --- Correction is here ---
          onChanged: (dynamic newValue) {
            // SfSlider provides dynamic, cast/convert it before calling the original callback
            if (newValue is double) {
              onChanged(newValue); // Call the ValueChanged<double>
            } else if (newValue is int) {
              // Sometimes sliders might yield int, especially at endpoints
              onChanged(newValue.toDouble());
            }
            // Optional: You could add an else block to handle unexpected types
          },
          // --- End of Correction ---
        ),
      ],
    );
  }

  Widget _buildPredictButton() {
    return ElevatedButton.icon(
      onPressed: _isLoading ? null : _predictCaseOutcome,
      icon: _isLoading
          ? Container( // Show spinner in button when loading
          width: 20, height: 20,
          margin: const EdgeInsets.only(right: 8),
          child: CircularProgressIndicator(strokeWidth: 2.5, color: primaryTextColor))
          : Icon(Feather.zap, size: 20), // Bolt icon
      label: Text(
        _isLoading ? "Analyzing..." : "Predict Outcome", // Dynamic label
        style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 16),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: accentColor, // Use constant
        foregroundColor: primaryTextColor, // Use constant
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(defaultRadius),
        ),
        padding: const EdgeInsets.symmetric(vertical: 16),
        elevation: 2,
        minimumSize: const Size(double.infinity, 50), // Ensure button takes full width
      ),
    );
  }

  Widget _buildLoadingIndicator() {
    return Center( // Center the loading indicator
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center, // Center vertically too
        children: [
          SizedBox(
            width: 50, // Slightly smaller
            height: 50,
            child: CircularProgressIndicator(
              strokeWidth: 3.5, // Thinner stroke
              valueColor: AlwaysStoppedAnimation<Color>(primaryTextColor), // Use constant
            ),
          ),
          const SizedBox(height: defaultPadding * 0.8),
          Text(
            "AI is processing your case...",
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              color: secondaryTextColor, // Use constant
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsSection() {
    // Add a top margin only when results are shown
    return Padding(
      padding: const EdgeInsets.only(top: defaultPadding * 1.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            "Prediction Results",
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: primaryTextColor, // Use constant
            ),
          ),
          const SizedBox(height: defaultPadding),
          Card(
            elevation: 4, // Keep elevation for result card
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(defaultRadius),
            ),
            color: Colors.white, // Explicit white background
            child: Padding(
              padding: const EdgeInsets.all(defaultPadding),
              child: Column(
                children: [
                  // Score Animation (Already uses _scoreAnimation which is updated)
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 160, // Slightly smaller gauge
                        height: 160,
                        child: CircularProgressIndicator(
                          value: _scoreAnimation.value / 100.0, // Use animated value
                          strokeWidth: 14, // Thicker stroke for gauge
                          backgroundColor: Colors.blueGrey[50],
                          valueColor: AlwaysStoppedAnimation<Color>(
                            _getScoreColor(_predictionScore), // Color based on final score
                          ),
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            "AI score ${_scoreAnimation.value.round()}/100",
                            style: GoogleFonts.poppins(
                              fontSize: 38, // Larger score text
                              fontWeight: FontWeight.w700,
                              color: _getScoreColor(_predictionScore),
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            _getScoreInterpretation(_predictionScore),
                            style: GoogleFonts.poppins(
                                color: secondaryTextColor, // Use constant
                                fontSize: 15,
                                fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: defaultPadding * 1.2),
                  Text(
                    AiConfig.advisoryNotice,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      color: Colors.orange[800],
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(height: defaultPadding),
                  Divider(color: Colors.blueGrey[100], thickness: 1), // Separator
                  const SizedBox(height: defaultPadding * 0.8),

                  // --- Use MarkdownBody for Analysis ---
                  Align(
                    alignment: Alignment.topLeft,
                    child: MarkdownBody(
                      data: _predictionAnalysis, // The analysis string from API
                      selectable: true, // Allow text selection
                      styleSheet: MarkdownStyleSheet(
                        p: GoogleFonts.poppins(fontSize: 15, color: primaryTextColor, height: 1.55),
                        h2: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w600, color: primaryTextColor, height: 1.8),
                        strong: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                        listBullet: GoogleFonts.poppins(fontSize: 15, color: primaryTextColor, height: 1.55),
                        // Add more styles as needed
                      ),
                    ),
                  ),
                  // --- END OF MarkdownBody ---
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // No changes needed for _showHowItWorksDialog or _buildAlgorithmStep
  // (Assuming their UI is acceptable)
  void _showHowItWorksDialog() {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(defaultRadius),
        ),
        child: Container(
          padding: const EdgeInsets.all(defaultPadding * 1.2),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(defaultRadius),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Feather.info, color: primaryTextColor),
                  const SizedBox(width: 12),
                  Text(
                    "How Case Prediction Works",
                    style: GoogleFonts.poppins(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: primaryTextColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: defaultPadding),
              _buildAlgorithmStep(
                icon: Feather.database,
                title: "User-Provided Case Summary",
                description: "Does not query a verified case-law database. It summarizes only the facts and inputs you provide and may miss or invent legal authorities.",
                iconColor: Colors.blue[600]!,
              ),
              const SizedBox(height: defaultPadding * 0.8),
              _buildAlgorithmStep(
                icon: Feather.sliders, // Different icon
                title: "User-Provided Rating Inputs",
                description: "Your subjective factor ratings are supplied as context to the AI; they are not statistically validated weights.",
                iconColor: Colors.purple[600]!,
              ),
              const SizedBox(height: defaultPadding * 0.8),
              _buildAlgorithmStep(
                icon: Feather.trending_up,
                title: "Illustrative AI Rating",
                description: "The displayed score is a model-generated illustration, not an empirical success probability or a guarantee.",
                iconColor: Colors.green[600]!,
              ),
              const SizedBox(height: defaultPadding * 1.2),
              Container( // Add a subtle background for the disclaimer
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: Colors.amber.withAlpha((0.2 * 255).toInt()),
                    borderRadius: BorderRadius.circular(8)
                ),
                child: Text(
                  "Disclaimer: This tool provides AI-driven estimates for informational purposes only. It is not legal advice and does not guarantee outcomes. Always consult a qualified legal professional.",
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                      color: Colors.orange[800], // Darker orange
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                      height: 1.4
                  ),
                ),
              ),
              const SizedBox(height: defaultPadding * 1.2),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: appBarColor, // Use AppBar color for consistency
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(defaultRadius),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14), // Adjusted padding
                  ),
                  child: Text(
                    "Understood", // Changed text
                    style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w500,
                        fontSize: 16
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAlgorithmStep({
    required IconData icon,
    required String title,
    required String description,
    required Color iconColor, // Added color parameter
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(10), // Slightly larger padding
          decoration: BoxDecoration(
            color: iconColor.withAlpha((0.2 * 255).toInt()), // Use parameter color with opacity
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 20, color: iconColor), // Use parameter color
        ),
        const SizedBox(width: 14), // Increased spacing
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.poppins(
                  fontWeight: FontWeight.w600,
                  color: primaryTextColor,
                  fontSize: 15, // Slightly smaller title
                ),
              ),
              const SizedBox(height: 5), // Adjust spacing
              Text(
                description,
                style: GoogleFonts.poppins(
                  color: secondaryTextColor,
                  fontSize: 14, // Slightly smaller description
                  height: 1.4, // Adjust line height
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}