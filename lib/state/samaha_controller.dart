import 'package:flutter/foundation.dart';
import '../models/samaha_catalog.dart';

enum SamahaLoadState { idle, loading, ready, error }

/// Feature-scoped state; consumes the standalone local asset loader.
/// Language changes do not alter authentication or unrelated English screens.
class SamahaController extends ChangeNotifier {
  SamahaController({
    required Future<SamahaCatalog> Function() loader,
    String language = 'en',
  }) : _loader = loader,
       _language = language.startsWith('ar') ? 'ar' : 'en';
  final Future<SamahaCatalog> Function() _loader;
  String _language;
  int _generation = 0;
  bool _disposed = false;
  SamahaLoadState _state = SamahaLoadState.idle;
  SamahaCatalog? _catalog;
  Object? _error;

  String get language => _language;
  SamahaLoadState get state => _state;
  SamahaCatalog? get catalog => _catalog;
  Object? get error => _error;

  void setLanguage(String language) {
    final next = language.startsWith('ar') ? 'ar' : 'en';
    if (_disposed || next == _language) return;
    _language = next;
    notifyListeners();
  }

  Future<void> load() async {
    if (_disposed) return;
    final generation = ++_generation;
    _state = SamahaLoadState.loading;
    _catalog = null; // A failed local asset read is not a successful reload.
    _error = null;
    notifyListeners();
    try {
      final result = await _loader();
      if (_disposed || generation != _generation) return;
      _catalog = result;
      _state = SamahaLoadState.ready;
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _error = error;
      _state = SamahaLoadState.error;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
