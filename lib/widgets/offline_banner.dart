import 'package:flutter/material.dart';

/// Small inline "you're offline" chip-style banner.
///
/// Where it shows:
/// - HomeScreen, right under the header (above the category chips)
///
/// Behavior:
/// - Does NOT try to reconnect or offer actions here — it's just informational.
/// - Copy explains we're falling back to cached content.
///
/// Visual:
/// - Rounded pill-ish container
/// - Uses Material colorScheme.errorContainer / onErrorContainer,
///   but slightly translucent so it doesn't scream.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.errorContainer.withOpacity(0.8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.wifi_off_rounded,
            color: cs.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'You’re offline. Showing cached items if available.',
              style: TextStyle(
                color: cs.onErrorContainer,
                fontSize: 14,
                height: 1.3,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
