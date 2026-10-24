import 'package:flutter/material.dart';

/// "Bakit?" toggle that reveals the backend's `explain_tl` text under a
/// card. Renders nothing when there is no explanation to show.
class BakitExpander extends StatefulWidget {
  final String? text;
  final Color accent;

  const BakitExpander({
    super.key,
    required this.text,
    this.accent = const Color(0xFFF26E22),
  });

  @override
  State<BakitExpander> createState() => _BakitExpanderState();
}

class _BakitExpanderState extends State<BakitExpander> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.text?.trim() ?? '';
    if (text.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _open = !_open),
          // 48dp tall, Android's minimum touch target.
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Bakit?',
                  style: TextStyle(
                    color: widget.accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 2),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: widget.accent,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _open
              ? Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: widget.accent.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    text,
                    style: TextStyle(
                      color: Colors.grey[800],
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
