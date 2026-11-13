// The AI helper's label in the helper row and Settings › Helper: a catalog entry nobody has
// tried with its agent yet is "(untested)", in every language.
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/ai_dialog.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart';

void main() {
  tearDown(() => configureLanguage('en'));

  test('an unverified helper is labelled (untested); a tested or local one is not', () {
    expect(AiDialogState.helperName({'name': 'Gemini CLI', 'verified': false}), 'Gemini CLI (untested)');
    expect(AiDialogState.helperName({'name': 'Claude Code', 'verified': true}), 'Claude Code');
    expect(AiDialogState.helperName({'name': 'Claude Code'}), 'Claude Code');
    expect(AiDialogState.helperName({'name': 'pi · qwen', 'local': true, 'verified': true}), 'pi · qwen · on this PC');
    for (final code in ['de', 'fr', 'es', 'it', 'pt', 'nl', 'pl']) {
      configureLanguage(code);
      final label = AiDialogState.helperName({'name': 'Gemini CLI', 'verified': false});
      expect(label, startsWith('Gemini CLI ('), reason: code);
      expect(label, isNot('Gemini CLI (untested)'), reason: code);
    }
  });
}
