import 'package:flutter/material.dart';

import 'setup_ui.dart';
import 'wifi_setup_screens.dart';

/// Test Mode viewer for the first-run setup flow: every page of it, in
/// order, built from the real setup widgets with sample data — no
/// Bluetooth, no Firebase, nothing saved. Buttons on the pages do nothing;
/// the floating bar steps through them, and tapping its title lists them
/// all to jump to one.
class SetupPreviewScreen extends StatefulWidget {
  const SetupPreviewScreen({super.key});

  @override
  State<SetupPreviewScreen> createState() => _SetupPreviewScreenState();
}

/// The two sections of the preview. Each has its own cycle: ◀ / ▶ and
/// swiping stay inside the current one.
enum _Section { flow, animation }

class _SetupPreviewScreenState extends State<SetupPreviewScreen> {
  _Section _section = _Section.flow;
  PageController _pager = PageController();
  int _index = 0;
  bool _barCollapsed = false;

  /// Bumped to rebuild a page from scratch (fresh state and animations).
  final Map<String, int> _restarts = {};

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  List<SetupPreviewPage> _pagesOf(SetupPreviewSections sections, _Section section) =>
      section == _Section.flow ? sections.flow : sections.animation;

  void _goTo(int index, int count) {
    if (index < 0 || index >= count) return;
    if (MediaQuery.disableAnimationsOf(context) || (index - _index).abs() > 1) {
      _pager.jumpToPage(index);
    } else {
      _pager.animateToPage(index, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    }
  }

  /// Switches to [section] at [index] with a fresh pager for its cycle.
  void _openSection(_Section section, int index) {
    FocusManager.instance.primaryFocus?.unfocus();
    final old = _pager;
    setState(() {
      _section = section;
      _index = index;
      _pager = PageController(initialPage: index);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  String _restartKey(int index) => '${_section.name}-$index';

  void _restart(int index) {
    final key = _restartKey(index);
    setState(() => _restarts[key] = (_restarts[key] ?? 0) + 1);
  }

  Future<void> _showPageList(SetupPreviewSections sections) async {
    final picked = await showModalBottomSheet<(_Section, int)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSetupPanel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) => _PageList(sections: sections, section: _section, current: _index),
    );
    if (picked == null || !mounted) return;
    final (section, index) = picked;
    if (section == _section) {
      _goTo(index, _pagesOf(sections, section).length);
    } else {
      _openSection(section, index);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilt every frame so a hot reload picks up edits to the page list.
    final sections = setupPreviewSections();
    final pages = _pagesOf(sections, _section);
    final page = pages[_index];

    return Material(
      color: kSetupField,
      child: Stack(
        children: [
          PageView.builder(
            key: ValueKey(_section),
            controller: _pager,
            itemCount: pages.length,
            onPageChanged: (i) {
              FocusManager.instance.primaryFocus?.unfocus();
              setState(() => _index = i);
            },
            itemBuilder: (_, i) => _PreviewPage(
              key: ValueKey('${_restartKey(i)}-${_restarts[_restartKey(i)] ?? 0}'),
              builder: (pageContext) => pages[i].builder(pageContext, () => _restart(i)),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Center(
                child: _ControlBar(
                  collapsed: _barCollapsed,
                  position: '${_index + 1} / ${pages.length}',
                  group: page.group,
                  label: page.label,
                  note: page.note,
                  onPrevious: _index > 0 ? () => _goTo(_index - 1, pages.length) : null,
                  onNext: _index < pages.length - 1 ? () => _goTo(_index + 1, pages.length) : null,
                  onList: () => _showPageList(sections),
                  onClose: () => Navigator.of(context).pop(),
                  onToggle: () => setState(() => _barCollapsed = !_barCollapsed),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One preview page in its own navigator, so the page's Back button and
/// any push/pop it does stay inside the page instead of leaving the
/// preview, and its sheets open over it.
class _PreviewPage extends StatelessWidget {
  final WidgetBuilder builder;
  const _PreviewPage({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    return HeroControllerScope.none(
      child: Navigator(
        onGenerateInitialRoutes: (_, _) => [
          PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            pageBuilder: (pageContext, _, _) => builder(pageContext),
          ),
        ],
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  final bool collapsed;
  final String position;
  final String group;
  final String label;
  final String? note;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onList;
  final VoidCallback onClose;
  final VoidCallback onToggle;

  const _ControlBar({
    required this.collapsed,
    required this.position,
    required this.group,
    required this.label,
    this.note,
    required this.onPrevious,
    required this.onNext,
    required this.onList,
    required this.onClose,
    required this.onToggle,
  });

  static const _text = TextStyle(fontFamily: kSetupFont, color: Colors.white, height: 1.2);

  @override
  Widget build(BuildContext context) {
    final iconColor = Colors.white;
    final disabled = Colors.white.withValues(alpha: 0.3);

    Widget button(IconData icon, String tooltip, VoidCallback? onPressed) => IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      color: iconColor,
      disabledColor: disabled,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );

    final child = collapsed
        ? InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(position, style: _text.copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 4),
                  Icon(Icons.expand_more_rounded, size: 20, color: iconColor),
                ],
              ),
            ),
          )
        : Row(
            children: [
              button(Icons.close_rounded, 'Close preview', onClose),
              button(Icons.chevron_left_rounded, 'Previous page', onPrevious),
              Expanded(
                child: InkWell(
                  onTap: onList,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$position · $group',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _text.copyWith(fontSize: 12, color: Colors.white70),
                        ),
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _text.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        if (note != null)
                          Text(
                            note!,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: _text.copyWith(fontSize: 11, color: const Color(0xFFFFC9A3)),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              button(Icons.chevron_right_rounded, 'Next page', onNext),
              button(Icons.expand_less_rounded, 'Hide controls', onToggle),
            ],
          );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Material(
          color: kSetupInk.withValues(alpha: 0.92),
          elevation: 6,
          shadowColor: Colors.black45,
          borderRadius: BorderRadius.circular(collapsed ? 20 : 24),
          child: Padding(padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 4), child: child),
        ),
      ),
    );
  }
}

/// Every preview page under its group heading — the setup flow, then the
/// "needs animation" section set apart below it. Pops with the tapped
/// page's section and index.
class _PageList extends StatelessWidget {
  final SetupPreviewSections sections;
  final _Section section;
  final int current;
  const _PageList({required this.sections, required this.section, required this.current});

  static const _groupStyle = TextStyle(
    fontFamily: kSetupFont,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
    color: kSetupMuted,
  );

  List<Widget> _tiles(BuildContext context, _Section of, List<SetupPreviewPage> pages) {
    return [
      for (var i = 0; i < pages.length; i++) ...[
        if (of == _Section.flow && (i == 0 || pages[i - 1].group != pages[i].group))
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
            child: Text(pages[i].group.toUpperCase(), style: _groupStyle),
          ),
        _tile(context, of, i, pages[i]),
      ],
    ];
  }

  Widget _tile(BuildContext context, _Section of, int i, SetupPreviewPage page) {
    final selected = of == section && i == current;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      dense: true,
      selected: selected,
      selectedColor: kSetupAccent,
      leading: Text('${i + 1}', style: const TextStyle(fontFamily: kSetupFont, fontSize: 13, color: kSetupMuted)),
      minLeadingWidth: 24,
      title: Text(
        page.label,
        style: TextStyle(fontFamily: kSetupFont, fontSize: 15, fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
      ),
      subtitle: page.note == null
          ? null
          : Text(page.note!, style: const TextStyle(fontFamily: kSetupFont, fontSize: 12, color: kSetupMuted)),
      trailing: selected ? const Icon(Icons.check_rounded) : null,
      onTap: () => Navigator.of(context).pop((of, i)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.only(top: 12, bottom: 24),
        children: [
          ..._tiles(context, _Section.flow, sections.flow),
          // Its own section, with its own ◀ / ▶ cycle.
          Container(
            margin: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            padding: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: const Color(0xFFFCE3D2), borderRadius: BorderRadius.circular(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: Row(
                    children: [
                      const Icon(Icons.animation_rounded, size: 18, color: kSetupAccent),
                      const SizedBox(width: 8),
                      Text(kNeedsAnimationGroup.toUpperCase(), style: _groupStyle.copyWith(color: kSetupAccent)),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 4),
                  child: Text(
                    'Separate set: ◀ / ▶ cycles only these ${sections.animation.length}.',
                    style: const TextStyle(fontFamily: kSetupFont, fontSize: 12, color: kSetupMuted),
                  ),
                ),
                ..._tiles(context, _Section.animation, sections.animation),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
