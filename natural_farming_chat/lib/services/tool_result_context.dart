/// One executed tool result as the model-facing prompt sees it.
class PromptToolResult {
  final String toolName;
  final bool success;
  final String text;

  const PromptToolResult({
    required this.toolName,
    required this.success,
    required this.text,
  });
}

/// Mirror `run_hf_gpu_tool_benchmark.tool_result_context` byte for byte.
///
/// The runner joins `Tool Results:`, a `--- <name> ---` header, the text (or
/// `Error: <text>`), and a blank line for every result, then appends the join's
/// trailing newline. `ToolExecutor.formatResultsForPrompt` and the parity
/// exporter both use this function so they cannot drift.
String formatToolResultsForPrompt(Iterable<PromptToolResult> results) {
  if (results.isEmpty) return '';

  final buffer = StringBuffer('Tool Results:\n');
  for (final result in results) {
    buffer.writeln('--- ${result.toolName} ---');
    buffer.writeln(result.success ? result.text : 'Error: ${result.text}');
    buffer.writeln();
  }
  return buffer.toString();
}
