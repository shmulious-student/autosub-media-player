// FirstRunWizard — first-run setup (SPEC §11, SCREENS §1).
//
// Two steps, both backed by REAL local checks (no fake progress):
//   1. Drive check — is the model drive present? Missing is a hard blocker with
//      the trust copy (DS §7); "Choose location…" repoints it, "Try again" re-checks.
//   2. Models — which AI models are already on the drive (a real presence check).
//      Missing models aren't a blocker: the engine fetches them on first use, so
//      we say so plainly rather than showing a download bar we can't drive yet.
//
// On finish, settings.setupComplete is set so the wizard never gates again.

import 'dart:io';

import 'package:flutter/material.dart';

import '../platform/secure_files.dart';
import '../settings/app_settings.dart';
import '../ui/bidi.dart';
import '../ui/components/model_download_row.dart';
import '../ui/components/status_chip.dart';
import '../ui/components/wizard_step.dart';
import '../ui/tokens.dart';
import 'model_catalog.dart';

class FirstRunWizard extends StatefulWidget {
  const FirstRunWizard({
    super.key,
    required this.settings,
    required this.onComplete,
  });

  final AppSettings settings;
  final VoidCallback onComplete;

  @override
  State<FirstRunWizard> createState() => _FirstRunWizardState();
}

class _FirstRunWizardState extends State<FirstRunWizard> {
  int _step = 0;

  AppSettings get s => widget.settings;

  bool get _driveFound {
    try {
      return Directory(s.modelLocation).existsSync();
    } catch (_) {
      return false;
    }
  }

  Future<void> _chooseLocation() async {
    final picked = await const SecureFiles().pickFolder();
    if (picked == null) return;
    s.modelLocation = picked.path;
    setState(() {});
  }

  void _finish() {
    s.setupComplete = true;
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.neutral950,
      body: _step == 0 ? _driveStep() : _modelsStep(),
    );
  }

  // --- Step 1: drive check -------------------------------------------------

  Widget _driveStep() {
    final found = _driveFound;
    return WizardStep(
      stepIndex: 0,
      stepCount: 2,
      headline: 'Set up AutoSub',
      body: 'AutoSub keeps its AI models on your external drive, so they never '
          'fill up your Mac.',
      actions: [
        if (!found)
          OutlinedButton(
              onPressed: _chooseLocation,
              child: const Text('Choose location…')),
        if (!found)
          OutlinedButton(
              onPressed: () => setState(() {}),
              child: const Text('Try again')),
        FilledButton(
          onPressed: found ? () => setState(() => _step = 1) : null,
          child: const Text('Continue'),
        ),
      ],
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.x5),
        decoration: BoxDecoration(
          color: found ? AppColors.readyTint : AppColors.attentionTint,
          borderRadius: const BorderRadius.all(AppRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusChip(
                  style: found ? StatusStyles.ready : StatusStyles.attention,
                  label: found ? 'Drive found' : 'Model drive not found',
                  size: StatusChipSize.md,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.x3),
            if (found)
              LtrIsland(
                child: Text(s.modelLocation,
                    style: AppType.monoTime
                        .copyWith(color: AppColors.textSecondary)),
              )
            else
              Text(
                'Connect the drive that holds your models, or choose a new '
                'location. Nothing else is blocked — your library is safe.',
                style: AppType.body.copyWith(color: AppColors.textSecondary),
              ),
          ],
        ),
      ),
    );
  }

  // --- Step 2: models ------------------------------------------------------

  Widget _modelsStep() {
    final root = s.modelLocation;
    final rows = [
      for (final m in kModelCatalog)
        ModelDownloadRow(
          name: m.name,
          size: m.approxSize,
          purpose: m.purpose,
          state: isModelPresent(root, m)
              ? ModelRowState.present
              : ModelRowState.missing,
        ),
    ];
    final anyMissing =
        kModelCatalog.any((m) => m.required && !isModelPresent(root, m));

    return WizardStep(
      stepIndex: 1,
      stepCount: 2,
      headline: anyMissing ? 'Models' : "You're set",
      body: anyMissing
          ? 'AutoSub downloads any missing models the first time it processes a '
              'title — once, to your external drive. It never bundles models or '
              'uses your system disk.'
          : 'Your models are ready on the drive.',
      actions: [
        OutlinedButton(
            onPressed: () => setState(() => _step = 0),
            child: const Text('Back')),
        FilledButton(onPressed: _finish, child: const Text('Open library')),
      ],
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.neutral900,
          borderRadius: const BorderRadius.all(AppRadius.lg),
          border: Border.all(color: AppColors.hairline),
        ),
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: AppColors.hairline),
              rows[i],
            ],
          ],
        ),
      ),
    );
  }
}
