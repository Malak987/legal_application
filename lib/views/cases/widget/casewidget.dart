// utils/form_constants.dart (Example)
import 'package:flutter/material.dart';
import 'package:legalserviceapp/constants/colors.dart';

const Color primaryRed = AppColors.buttonColor;
const Color inputFillColor = Color(0xFFE0E0E0); // Light grey for inputs
const Color labelColor = Colors.black54;
const Color requiredStarColor = Colors.red;
const double fieldVerticalPadding = 12.0;
const double labelBottomPadding = 4.0;

// --- Reusable Widgets --- (Could be in a separate file)

// Helper for the main red header bar
Widget buildHeader(String title) {
  return Container(
    width: double.infinity,
    color: primaryRed,
    padding: const EdgeInsets.symmetric(vertical: 12.0),
    child: Text(
      title,
      textAlign: TextAlign.center,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 18.0,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

// Helper for the underlined section title (e.g., "By Case Number")
Widget buildSectionTitle(String title) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 16.0),
    child: Text(
      title,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.bold,
        decoration: TextDecoration.underline,
        color: Colors.black87,
      ),
    ),
  );
}

// Helper for Text Field Label Row (Label + Red Star)
Widget buildLabel(String text, {bool isRequired = true}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: labelBottomPadding),
    child: Row(
      children: [
        Text(
          text,
          style: const TextStyle(
            color: labelColor,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (isRequired)
          const Text(
            '*',
            style: TextStyle(
              color: requiredStarColor,
              fontWeight: FontWeight.bold,
            ),
          ),
      ],
    ),
  );
}

// Helper for styling TextFormFields consistently
InputDecoration buildInputDecoration(String hintText) {
  return InputDecoration(
    hintText: hintText,
    hintStyle: TextStyle(color: Colors.grey[600]),
    filled: true,
    fillColor: inputFillColor,
    contentPadding: const EdgeInsets.symmetric(
      vertical: 12.0,
      horizontal: 12.0,
    ),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8.0),
      borderSide: BorderSide.none, // No border line
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8.0),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8.0),
      borderSide: BorderSide.none, // Or maybe a subtle border on focus
    ),
  );
}

// Helper for the Search Button
Widget buildSearchButton(VoidCallback onPressed) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 20.0),
    child: ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: primaryRed,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14.0),
        minimumSize: const Size(double.infinity, 50), // Full width
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
        elevation: 3,
      ),
      child: const Text(
        'Search',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    ),
  );
}

// Helper for Radio Button Group
enum CaseStatusOption { pending, disposed, both }

Widget buildStatusRadioGroup({
  required CaseStatusOption? groupValue,
  required ValueChanged<CaseStatusOption?> onChanged,
}) {
  return Row(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: <Widget>[
      _buildRadioItem(
        CaseStatusOption.pending,
        'Pending',
        groupValue,
        onChanged,
      ),
      _buildRadioItem(
        CaseStatusOption.disposed,
        'Disposed',
        groupValue,
        onChanged,
      ),
      _buildRadioItem(CaseStatusOption.both, 'Both', groupValue, onChanged),
    ],
  );
}

Widget _buildRadioItem(
  CaseStatusOption value,
  String label,
  CaseStatusOption? groupValue,
  ValueChanged<CaseStatusOption?> onChanged,
) {
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Radio<CaseStatusOption>(
        value: value,
        groupValue: groupValue,
        onChanged: onChanged,
        activeColor: primaryRed,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      GestureDetector(
        onTap: () => onChanged(value),
        child: Text(label, style: const TextStyle(color: labelColor)),
      ),
      const SizedBox(width: 5), // Small spacing if needed
    ],
  );
}
