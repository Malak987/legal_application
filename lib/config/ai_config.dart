/// Client-side names and user-facing messages for server-backed AI features.
///
/// Provider credentials never belong in a Flutter build. Gemini calls are made
/// only by the authenticated `ai-assistant` Supabase Edge Function, which reads
/// its secret from server configuration.
class AiConfig {
  const AiConfig._();

  static const String edgeFunction = 'ai-assistant';
  static const String unavailableMessage =
      'AI assistance is not available right now. Please try again later.';
  static const String advisoryNotice =
      'AI output is informational only, may be incomplete or incorrect, and is not legal advice.';
}
