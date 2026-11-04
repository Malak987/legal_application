import 'package:flutter/material.dart';

import 'act.dart';

/// Compatibility route for existing callers; case data is loaded by ID from
/// the caller-authorized case detail endpoint.
class CaseStatusScreen extends StatelessWidget {
  const CaseStatusScreen({super.key, required this.caseId});

  final String caseId;

  @override
  Widget build(BuildContext context) => CaseDetailsScreen(caseId: caseId);
}
