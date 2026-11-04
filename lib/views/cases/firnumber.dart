// screens/search_by_fir_number_screen.dart
import 'package:flutter/material.dart';
import 'package:legalserviceapp/views/cases/widget/casewidget.dart';

class SearchByFirNumberScreen extends StatefulWidget {
  const SearchByFirNumberScreen({super.key});

  @override
  State<SearchByFirNumberScreen> createState() =>
      _SearchByFirNumberScreenState();
}

class _SearchByFirNumberScreenState extends State<SearchByFirNumberScreen> {
  final _formKey = GlobalKey<FormState>();
  String? _selectedCourtComplex;
  String? _selectedPoliceStation;
  final _firNumberController = TextEditingController();
  final _yearController = TextEditingController();
  CaseStatusOption? _selectedStatus = CaseStatusOption.pending; // Default

  // --- Placeholder Data ---
  final List<String> _courtComplexOptions = [
    'District Court Complex',
    'High Court Complex',
    'Supreme Court Complex',
  ];
  final List<String> _policeStationOptions = [
    'Central Station',
    'North Station',
    'South Station',
  ];
  // -------------------------

  @override
  void dispose() {
    _firNumberController.dispose();
    _yearController.dispose();
    super.dispose();
  }

  void _performSearch() {
    if (_formKey.currentState!.validate()) {
      // Basic validation for radio button too, if needed
      if (_selectedStatus == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please select a status (Pending/Disposed/Both)'),
          ),
        );
        return; // Stop search if status not selected
      }
      // Process data

      // Add your API call or search logic here
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Status By FIR Number'),
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
                    buildSectionTitle('By FIR Number'),

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

                    // Police Station Dropdown
                    buildLabel('Police Station'),
                    DropdownButtonFormField<String>(
                      value: _selectedPoliceStation,
                      items:
                          _policeStationOptions
                              .map(
                                (String value) => DropdownMenuItem<String>(
                                  value: value,
                                  child: Text(value),
                                ),
                              )
                              .toList(),
                      onChanged:
                          (val) => setState(() => _selectedPoliceStation = val),
                      decoration: buildInputDecoration('Select Police Station'),
                      validator:
                          (value) =>
                              value == null
                                  ? 'Please select Police Station'
                                  : null,
                      isExpanded: true,
                    ),
                    const SizedBox(height: fieldVerticalPadding),

                    // FIR Number Text Field
                    buildLabel('FIR Number'),
                    TextFormField(
                      controller: _firNumberController,
                      decoration: buildInputDecoration('Type FIR Number'),
                      validator:
                          (value) =>
                              (value == null || value.isEmpty)
                                  ? 'Please enter FIR Number'
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
                    const SizedBox(
                      height: fieldVerticalPadding + 5,
                    ), // Extra padding before radio
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
