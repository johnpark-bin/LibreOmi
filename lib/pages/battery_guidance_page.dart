/// OEM-specific instructions for keeping LibreOmi's foreground service alive
/// through the vendor's own battery management. See
/// `lib/platform/battery_optimization.dart` for the guidance data model and
/// `docs/04-android-platform-notes.md` §3 and §11 for the background.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/battery_optimization.dart';
import '../platform/battery_optimization_gateway.dart';

class BatteryGuidancePage extends StatefulWidget {
  const BatteryGuidancePage({super.key, this.batteryOptimizationOverride});

  /// Injected for widget tests so they never touch a plugin channel, and so
  /// the async resolve path this page actually ships is the one under test.
  /// Defaults to the app-wide instance.
  final BatteryOptimization? batteryOptimizationOverride;

  @override
  State<BatteryGuidancePage> createState() => _BatteryGuidancePageState();
}

class _BatteryGuidancePageState extends State<BatteryGuidancePage> {
  OemGuidance? _guidance;

  @override
  void initState() {
    super.initState();
    _loadGuidance();
  }

  Future<void> _loadGuidance() async {
    final optimization =
        widget.batteryOptimizationOverride ?? batteryOptimization;
    OemGuidance resolved;
    try {
      resolved = await optimization.guidance();
    } catch (e) {
      // Never leave the page spinning on a plugin failure: the generic steps
      // are still useful, and the vendor lookup is only a refinement.
      debugPrint('battery optimisation: manufacturer lookup failed: $e');
      resolved = genericGuidance;
    }
    if (!mounted) {
      return;
    }
    setState(() => _guidance = resolved);
  }

  @override
  Widget build(BuildContext context) {
    final guidance = _guidance;
    return Scaffold(
      appBar: AppBar(title: const Text('Background reliability')),
      body: guidance == null
          ? const Center(child: CircularProgressIndicator())
          : _GuidanceView(guidance: guidance),
    );
  }
}

class _GuidanceView extends StatelessWidget {
  const _GuidanceView({required this.guidance});

  final OemGuidance guidance;

  Future<void> _copyLink(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: guidance.url));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Link copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          guidance.vendor,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Some phone makers kill background services even while LibreOmi '
          'keeps a foreground notification running. Follow the steps below '
          'in your phone\'s own settings app so recording is not stopped '
          'while the app is in the background.',
          style: TextStyle(
            color: theme.colorScheme.onSurface.withOpacity(0.7),
          ),
        ),
        const SizedBox(height: 24),
        _buildSectionHeader(context, 'Steps'),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < guidance.steps.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                ListTile(
                  leading: CircleAvatar(child: Text('${i + 1}')),
                  title: Text(guidance.steps[i]),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
        _buildSectionHeader(context, 'Full write-up'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(guidance.url),
                const SizedBox(height: 12),
                // The link is copied rather than opened because
                // `url_launcher` is deliberately not a dependency yet (see
                // the follow-up issue tracking that addition).
                OutlinedButton.icon(
                  onPressed: () => _copyLink(context),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy link'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 12),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 12,
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
