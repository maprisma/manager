import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf, uiLabel;
import 'package:flutter/material.dart';

import 'backend.dart' show ServiceError;
import 'jobs_model.dart';
import 'theme.dart';

/// The log sheet at the bottom of the list: the job that runs (or ran last), its phase, its log
/// as it comes, Cancel (disabled with the reason when it can't be), the result, and how many wait.
class JobSheet extends StatefulWidget {
  const JobSheet({super.key, required this.jobs, required this.onClose, this.height = 260});
  final JobsModel jobs;
  final VoidCallback onClose;
  final double height;
  @override
  State<JobSheet> createState() => _JobSheetState();
}

String phaseName(String phase) => switch (phase) {
  'queued' => tr('Waiting'),
  'prepare' => tr('Preparing'),
  'build' => tr('Building'),
  'commit' => tr('Installing'),
  'verify' => tr('Checking'),
  'finish' => tr('Finishing'),
  _ => phase,
};

class _JobSheetState extends State<JobSheet> {
  final _scroll = ScrollController();
  int _lastLength = -1;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _follow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  String _cancelWhy(JobView j) {
    if (j.finished) return tr('It has ended');
    if (j.phase == 'commit' || j.data['committed'] == true) {
      return tr('It has started changing the app\'s files: stopping it now would leave the app half replaced');
    }
    if (j.phase == 'verify' || j.phase == 'finish') return tr('The app is already replaced: it is being checked');
    return tr('Not yet (the job is starting)');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final marks = markColors(context);
    return ListenableBuilder(
      listenable: widget.jobs,
      builder: (context, _) {
        final j = widget.jobs.shown;
        if (j == null) return SizedBox.shrink();
        final text = j.log.toString();
        if (text.length != _lastLength) {
          _lastLength = text.length;
          _follow();
        }
        final result = j.result;
        final ok = result['ok'] == true;
        final restart = result['restart'] == true;
        final queued = widget.jobs.queued;
        final IconData stateIcon;
        final Color stateColor;
        switch (j.state) {
          case 'succeeded':
            stateIcon = Icons.check_circle_outline;
            stateColor = marks.running;
          case 'failed' || 'interrupted':
            stateIcon = Icons.error_outline;
            stateColor = scheme.error;
          case 'cancelled':
            stateIcon = Icons.cancel_outlined;
            stateColor = scheme.onSurfaceVariant;
          default:
            stateIcon = Icons.sync;
            stateColor = scheme.primary;
        }
        final message = !j.finished
            ? null
            : restart
            ? tr('The new build is checked: Maprisma Settings restarts with it now.')
            : ok
            ? (result['up_to_date'] == true ? tr('Nothing new: the installed build is the folder\'s.') : tr('Done.'))
            : '${result['message'] ?? result['code'] ?? j.state}';
        return Material(
          key: ValueKey('job-sheet'),
          color: scheme.surfaceContainerLow,
          child: Container(
            height: widget.height,
            decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outlineVariant))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                  child: Row(
                    children: [
                      if (!j.finished)
                        SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: stateColor))
                      else
                        Icon(stateIcon, size: 20, color: stateColor),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(j.title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(width: 8),
                      _Chip(j.finished ? uiLabel(j.state) : phaseName(j.phase), color: stateColor),
                      if (queued > 0) ...[
                        const SizedBox(width: 8),
                        Tooltip(
                          message: tr('They start one after the other'),
                          child: _Chip(trf('{0} more queued', [queued]), color: scheme.onSurfaceVariant),
                        ),
                      ],
                      Spacer(),
                      if (!j.finished)
                        Tooltip(
                          message: j.cancellable ? tr('Stop it: nothing of the app has been changed yet') : _cancelWhy(j),
                          child: TextButton(
                            onPressed: j.cancellable
                                ? () async {
                                    try {
                                      await widget.jobs.cancel(j);
                                    } on ServiceError catch (e) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trf('Not cancelled: {0}', [e.reason ?? e.code]))));
                                      }
                                    }
                                  }
                                : null,
                            child: Text(tr('Cancel')),
                          ),
                        ),
                      IconButton(
                        tooltip: tr('Hide the log (Esc)'),
                        onPressed: widget.onClose,
                        icon: Icon(Icons.expand_more),
                      ),
                    ],
                  ),
                ),
                if (j.password && !j.finished)
                  _Note(
                    icon: Icons.lock_outline,
                    text: tr('This one asks for your password: pkexec shows its dialog when pacman runs (5 minutes, then it gives up and nothing changes).'),
                  ),
                if (message != null)
                  _Note(
                    icon: ok ? Icons.info_outline : Icons.error_outline,
                    text: message,
                    color: ok ? null : scheme.error,
                  ),
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(cornerSizes(context).control),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Scrollbar(
                      controller: _scroll,
                      child: SingleChildScrollView(
                        controller: _scroll,
                        child: SelectableText(
                          text.isEmpty ? tr('Waiting for the first output…') : text,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: monoFont(context), height: 1.35, color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, {required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(cornerSizes(context).control),
    ),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w600)),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.color});
  final IconData icon;
  final String text;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: c),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c))),
        ],
      ),
    );
  }
}
