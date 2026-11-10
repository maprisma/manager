import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, configureLanguage, currentLanguage, languageNames;
import 'package:flutter/material.dart';

import 'apps_page.dart';
import 'core_call.dart';
import 'jobs_model.dart';
import 'theme.dart';
import 'window.dart';

/// Maprisma Manager's window: the list page in the desktop's colours (`desktop.look`, read as
/// Maprisma Launcher reads them).
class ManagerApp extends StatefulWidget {
  const ManagerApp({super.key, required this.core, this.look = const {}, this.onRestart, this.checkOnStart = true, this.jobs});
  final CoreCall core;
  final Map<String, dynamic> look;
  final VoidCallback? onRestart;
  final bool checkOnStart;

  /// Tests pass their own (a shorter poll).
  final JobsModel? jobs;
  @override
  State<ManagerApp> createState() => _ManagerAppState();
}

class _ManagerAppState extends State<ManagerApp> with WidgetsBindingObserver {
  String languageSetting = 'auto';
  late Map<String, dynamic> look = widget.look;
  late final JobsModel jobs = widget.jobs ?? JobsModel(widget.core);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _titlebar();
    _language();
  }

  Future<void> _language() async {
    try {
      final settings = await widget.core('settings.get');
      languageSetting = settings['language'] as String? ?? 'auto';
      configureLanguage(languageSetting);
      if (mounted) setState(() {});
    } on Object {
      // Older cores and test doubles can omit settings.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.jobs == null) jobs.dispose();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => _reloadLook();

  Future<void> _reloadLook() async {
    try {
      final fresh = await widget.core('desktop.look');
      if (mounted) setState(() => look = fresh);
      _titlebar();
    } on Object {
      // the old look stays
    }
  }

  void _titlebar() {
    final platform = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    AppWindow.titlebar(appTheme(platform, look['colors'] as Map? ?? {}, 12).brightness == Brightness.dark);
  }

  @override
  Widget build(BuildContext context) {
    final radius = (look['rounding'] as int? ?? 12).toDouble();
    return MaterialApp(
      title: tr('Maprisma Manager'),
      locale: Locale(currentLanguage),
      supportedLocales: [for (final code in languageNames.keys) Locale(code)],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      debugShowCheckedModeBanner: false,
      theme: appTheme(MediaQuery.platformBrightnessOf(context), look['colors'] as Map? ?? {}, radius),
      home: AppsPage(core: widget.core, jobs: jobs, onRestart: widget.onRestart, checkOnStart: widget.checkOnStart, onLanguageChanged: _language, languageSetting: languageSetting),
    );
  }
}
