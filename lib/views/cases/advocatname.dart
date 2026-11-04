// screens/search_by_party_name_screen.dart
import 'package:flutter/material.dart';
import 'package:legalserviceapp/views/cases/widget/casewidget.dart';

class SearchByPartyNameScreen extends StatefulWidget {
  const SearchByPartyNameScreen({super.key});

  @override
  State<SearchByPartyNameScreen> createState() =>
      _SearchByPartyNameScreenState();
}

class _SearchByPartyNameScreenState extends State<SearchByPartyNameScreen> {
  final _formKey = GlobalKey<FormState>();
  String? _selectedCourtComplex;
  final _partyNameController = TextEditingController();
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
    _partyNameController.dispose();
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
        title: const Text('Status By Party Name'),
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
                    buildSectionTitle('By Party Name'),

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

                    // Petitioner/Respondent Text Field
                    // NOTE: Label in image is "Petitioner/Respondent", input placeholder is "Type Details". Adjust accordingly.
                    buildLabel('Petitioner/Respondent'),
                    TextFormField(
                      controller: _partyNameController,
                      decoration: buildInputDecoration(
                        'Type Party Name / Details',
                      ), // Adjusted hint
                      validator:
                          (value) =>
                              (value == null || value.isEmpty)
                                  ? 'Please enter Party Name'
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
