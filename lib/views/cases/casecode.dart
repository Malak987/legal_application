// screens/search_by_case_code_screen.dart
import 'package:flutter/material.dart';
import 'package:legalserviceapp/views/cases/widget/casewidget.dart';

class SearchByCaseCodeScreen extends StatefulWidget {
  const SearchByCaseCodeScreen({super.key});

  @override
  State<SearchByCaseCodeScreen> createState() => _SearchByCaseCodeScreenState();
}

class _SearchByCaseCodeScreenState extends State<SearchByCaseCodeScreen> {
  final _formKey = GlobalKey<FormState>();
  String? _selectedCourtComplex;
  final _filingNumberController =
      TextEditingController(); // Assuming Case Code relates to Filing Number
  final _yearController = TextEditingController();
  CaseStatusOption? _selectedStatus = CaseStatusOption.pending;

  // --- Placeholder Data ---
  final List<String> _courtComplexOptions = [
    'District Court Complex',
    'High Court Complex',
    'Supreme Court Complex',
  ];
  // -------------------------

  @override
  void dispose() {
    _filingNumberController.dispose();
    _yearController.dispose();
    super.dispose();
  }

  void _performSearch() {
    if (_formKey.currentState!.validate()) {
      if (_selectedStatus == null) {
        /* ... Status validation ... */
        return;
      }
      // Process data

      // Add your API call or search logic here
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Status By Case Code'),
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            /* ... Background Watermark ... */
            child: Opacity(
              opacity: 0.08,
              child: Image.network(
                'https://upload.wikimedia.org/wikipedia/commons/thumb/5/55/Emblem_of_India.svg/1200px-Emblem_of_India.svg.png',
                fit: BoxFit.contain,
              ),
            ),
          ),
          SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    buildHeader('Case Status'),
                    buildSectionTitle('By Case Code'),

                    // Court Complex Dropdown
                    buildLabel('Court Complex'),
                    DropdownButtonFormField<String>(
                      value: _selectedCourtComplex,
                      items:
                          _courtComplexOptions
                              .map(
                                (String value) => DropdownMenuItem<String>(
                                  value: value,
                                  child: Text(value),
                                ),
                              )
                              .toList(),
                      onChanged:
                          (val) => setState(() => _selectedCourtComplex = val),
                      decoration: buildInputDecoration('Select Court Complex'),
                      validator:
                          (value) =>
                              value == null
                                  ? 'Please select Court Complex'
                                  : null,
                      isExpanded: true,
                    ),
                    const SizedBox(height: fieldVerticalPadding),

                    // Filing Number / Case Code Text Field
                    buildLabel('Filing Number'), // Label from image
                    TextFormField(
                      controller: _filingNumberController,
                      decoration: buildInputDecoration(
                        'Type Filing Number',
                      ), // Hint from image
                      validator:
                          (value) =>
                              (value == null || value.isEmpty)
                                  ? 'Please enter Filing Number'
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
                    const SizedBox(height: fieldVerticalPadding + 5),

                    // Status Radio Buttons
                    buildStatusRadioGroup(
                      groupValue: _selectedStatus,
                      onChanged: (CaseStatusOption? value) {
                        setState(() {
                          _selectedStatus = value;
                        });
                      },
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
