// screens/search_by_case_number_screen.dart
import 'package:flutter/material.dart';
import 'package:legalserviceapp/views/cases/widget/casewidget.dart';
// Import your constants/helpers file

class SearchByCaseNumberScreen extends StatefulWidget {
  const SearchByCaseNumberScreen({super.key});

  @override
  State<SearchByCaseNumberScreen> createState() =>
      _SearchByCaseNumberScreenState();
}

class _SearchByCaseNumberScreenState extends State<SearchByCaseNumberScreen> {
  final _formKey = GlobalKey<FormState>();
  String? _selectedCourtComplex;
  String? _selectedCaseType;
  final _caseNumberController = TextEditingController();
  final _yearController = TextEditingController();

  // --- Placeholder Data --- (Replace with actual data fetching)
  final List<String> _courtComplexOptions = [
    'District Court Complex',
    'High Court Complex',
    'Supreme Court Complex',
  ];
  final List<String> _caseTypeOptions = [
    'Civil Suit',
    'Criminal Case',
    'Writ Petition',
  ];
  // -------------------------

  @override
  void dispose() {
    _caseNumberController.dispose();
    _yearController.dispose();
    super.dispose();
  }

  void _performSearch() {
    if (_formKey.currentState!.validate()) {
      // Process data

      // Add your API call or search logic here
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Optional AppBar if you want one separate from the header bar
      appBar: AppBar(
        title: const Text('Status By Case Number'), // Or keep it empty
        backgroundColor: Colors.white, // Or primaryRed
        elevation: 0,
        iconTheme: IconThemeData(
          color: Colors.black,
        ), // Adjust if AppBar bg is red
      ),
      body: Stack(
        children: [
          // --- Background Watermark ---
          Positioned.fill(
            child: Opacity(
              opacity: 0.08, // Adjust opacity as needed
              child: Image.network(
                'https://upload.wikimedia.org/wikipedia/commons/thumb/5/55/Emblem_of_India.svg/1200px-Emblem_of_India.svg.png', // Ensure path is correct
                fit: BoxFit.contain, // Or BoxFit.cover
              ),
            ),
          ),
          // --- Form Content ---
          SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    buildHeader('Case Status'), // Common Header
                    buildSectionTitle('By Case Number'), // Section Title
                    // Court Complex Dropdown
                    buildLabel('Court Complex'),
                    DropdownButtonFormField<String>(
                      value: _selectedCourtComplex,
                      items:
                          _courtComplexOptions.map((String value) {
                            return DropdownMenuItem<String>(
                              value: value,
                              child: Text(value),
                            );
                          }).toList(),
                      onChanged: (String? newValue) {
                        setState(() {
                          _selectedCourtComplex = newValue;
                        });
                      },
                      decoration: buildInputDecoration('Select Court Complex'),
                      validator:
                          (value) =>
                              value == null
                                  ? 'Please select Court Complex'
                                  : null,
                      isExpanded: true, // Makes dropdown take full width
                    ),
                    const SizedBox(height: fieldVerticalPadding),

                    // Case Type Dropdown
                    buildLabel('Case Type'),
                    DropdownButtonFormField<String>(
                      value: _selectedCaseType,
                      items:
                          _caseTypeOptions.map((String value) {
                            return DropdownMenuItem<String>(
                              value: value,
                              child: Text(value),
                            );
                          }).toList(),
                      onChanged: (String? newValue) {
                        setState(() {
                          _selectedCaseType = newValue;
                        });
                      },
                      decoration: buildInputDecoration('Select Case Type'),
                      validator:
                          (value) =>
                              value == null ? 'Please select Case Type' : null,
                      isExpanded: true,
                    ),
                    const SizedBox(height: fieldVerticalPadding),

                    // Case Number Text Field
                    buildLabel('Case Number'),
                    TextFormField(
                      controller: _caseNumberController,
                      decoration: buildInputDecoration('Type Case Number'),
                      keyboardType: TextInputType.text, // Adjust as needed
                      validator:
                          (value) =>
                              (value == null || value.isEmpty)
                                  ? 'Please enter Case Number'
                                  : null,
                    ),
                    const SizedBox(height: fieldVerticalPadding),

                    // Year Text Field
                    buildLabel('Year'),
                    TextFormField(
                      controller: _yearController,
                      decoration: buildInputDecoration('Type Year'),
                      keyboardType: TextInputType.number,
                      validator:
                          (value) =>
                              (value == null || value.isEmpty)
                                  ? 'Please enter Year'
                                  : null,
                    ),
                    const SizedBox(height: fieldVerticalPadding),

                    // Search Button
                    buildSearchButton(_performSearch),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
