import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import 'intro_scenes.dart';
import 'setup_ui.dart';

/// Pref written by the intro. Local only: nothing here talks to Firebase,
/// the backend or the monitor.
const String kIntroSeenPrefsKey = 'intro_seen';

// Same 40 / 16 scale and weights as the rest of setup.
const TextStyle _kDisplay = TextStyle(
  fontFamily: kSetupFont,
  fontSize: 40,
  height: 1.08,
  fontWeight: FontWeight.w400,
  letterSpacing: -1.2,
  color: kSetupOnField,
);
const TextStyle _kBody = TextStyle(
  fontFamily: kSetupFont,
  fontSize: 16,
  height: 1.5,
  fontWeight: FontWeight.w600,
  color: kSetupOnField,
);

// ── Intro (before setup) ────────────────────────────────────────────────────

/// Four short pages before any pairing starts, so setup isn't the first thing
/// a new user meets: a greeting, then three animated scenes that show what
/// GRID does (live power, the bill in pesos, a tip that lowers use) with only
/// a few words each. Nothing here talks to Firebase, the backend or the
/// monitor.
class IntroScreen extends StatefulWidget {
  /// Called after the last page or "Skip intro", once the intro is marked
  /// seen. The caller swaps in the next route.
  final void Function(BuildContext context) onDone;

  /// Setup preview only: open on this page and never touch prefs.
  final int initialPage;
  final bool preview;

  const IntroScreen({super.key, required this.onDone, this.initialPage = 0, this.preview = false});

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen> {
  static const _pageCount = 4;

  late int _page = widget.initialPage;

  void _goTo(int page) {
    if (page < 0 || page >= _pageCount) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _page = page);
  }

  Future<void> _finish() async {
    if (!widget.preview) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kIntroSeenPrefsKey, true);
    }
    if (mounted) widget.onDone(context);
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    final duration = reduce ? Duration.zero : const Duration(milliseconds: 260);

    return PopScope(
      // Nothing sits behind the intro on first run; system Back steps back a
      // page instead.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _page > 0) _goTo(_page - 1);
      },
      child: SetupScaffold(
        step: _page + 1,
        totalSteps: _pageCount,
        showBack: _page > 0,
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: (details) {
            final v = details.primaryVelocity ?? 0;
            if (v < -300) _goTo(_page + 1);
            if (v > 300) _goTo(_page - 1);
          },
          child: AnimatedSwitcher(
            duration: duration,
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
            layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
            child: KeyedSubtree(key: ValueKey(_page), child: _buildPage()),
          ),
        ),
        bottom: _buildBottom(),
      ),
    );
  }

  Widget _buildPage() {
    switch (_page) {
      case 0:
        // A greeting that settles in a piece at a time, so the first screen
        // doesn't land fully formed.
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 48),
              _EaseIn(
                delay: const Duration(milliseconds: 400),
                child: Semantics(header: true, child: const Text('Hi, welcome to GRID', style: _kDisplay)),
              ),
              const SizedBox(height: 12),
              _EaseIn(
                delay: const Duration(milliseconds: 800),
                child: const Text("Let's make your electric bill make sense.", style: _kBody),
              ),
            ],
          ),
        );
      case 1:
        return const _ScenePage(title: 'See it live.', subtitle: 'Your power use, as it happens.', scene: LiveScene());
      case 2:
        return const _ScenePage(title: 'Know your bill.', subtitle: 'In pesos, not jargon.', scene: BillScene());
      default:
        return const _ScenePage(title: 'Catch the unusual.', subtitle: 'Alerts start after your first month.', scene: AlertScene());
    }
  }

  Widget _buildBottom() {
    if (_page == _pageCount - 1) {
      return SetupPrimaryButton(label: 'Set up my monitor', onPressed: _finish);
    }
    final row = Row(
      children: [
        SetupTextLink(label: 'Skip intro', onPressed: _finish, alignStart: true),
        const Spacer(),
        SetupArrowButton(semanticLabel: 'Next', onPressed: () => _goTo(_page + 1)),
      ],
    );
    // On the greeting the controls arrive last, after the words.
    return _page == 0 ? _EaseIn(delay: const Duration(milliseconds: 1300), child: row) : row;
  }
}

/// A scene page: a few words at the top, the animation filling the rest.
class _ScenePage extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget scene;
  const _ScenePage({required this.title, required this.subtitle, required this.scene});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: SetupTitle(title: title, subtitle: subtitle),
        ),
        Expanded(
          child: Padding(padding: const EdgeInsets.fromLTRB(24, 32, 24, 16), child: scene),
        ),
      ],
    );
  }
}

/// Fades [child] in and lifts it a few pixels into place once, after [delay].
/// Shows it straight away under reduce-motion.
class _EaseIn extends StatefulWidget {
  final Duration delay;
  final Widget child;
  const _EaseIn({required this.delay, required this.child});

  @override
  State<_EaseIn> createState() => _EaseInState();
}

class _EaseInState extends State<_EaseIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  late final CurvedAnimation _curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.value = 1;
    } else {
      Future<void>.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curve,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(_curve),
        child: widget.child,
      ),
    );
  }
}

// ── Name your home (after setup) ────────────────────────────────────────────

/// The dashboard's home-name line, and the landing spot for the name flown in
/// from the setup's naming step. It shows the name like any text; while a
/// flight is under way it stays in place but hidden, so the flying copy lands
/// on it and takes over without a jump.
class HomeNameHero extends StatefulWidget {
  final String name;
  final TextStyle style;
  const HomeNameHero({super.key, required this.name, required this.style});

  /// The one on screen, where a flight lands.
  static _HomeNameHeroState? _active;

  /// True while a flight is under way.
  static final ValueNotifier<bool> flying = ValueNotifier(false);

  /// Flies [name] from [from] (screen coordinates, in [fromStyle]) to the
  /// dashboard's name line, shrinking into its style on the way. Draws in
  /// the root [overlay], above whatever route change is happening, so it
  /// survives the setup pages being removed. Waits for the dashboard to be
  /// on screen first; gives up quietly if it never is.
  ///
  /// The name is drawn at [from] straight away and holds still until
  /// [startAfter] completes (the route change, so the dashboard's heavy first
  /// build is over and the glide has the frames to itself).
  static Future<void> flyIn({
    required OverlayState overlay,
    required String name,
    required Rect from,
    required TextStyle fromStyle,
    Future<void>? startAfter,
  }) async {
    flying.value = true;
    Offset? toPos;
    TextStyle? toStyle;
    final progress = ValueNotifier<double>(0);
    final entry = OverlayEntry(
      builder: (_) => ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (_, v, _) {
          final e = Curves.easeInOutCubic.transform(v);
          final pos = Offset.lerp(from.topLeft, toPos ?? from.topLeft, e)!;
          final style = TextStyle.lerp(fromStyle, toStyle ?? fromStyle, e)!.copyWith(decoration: TextDecoration.none);
          return Positioned(
            left: pos.dx,
            top: pos.dy,
            child: IgnorePointer(
              child: Material(
                type: MaterialType.transparency,
                child: Text(name, style: style, maxLines: 1, softWrap: false, overflow: TextOverflow.visible),
              ),
            ),
          );
        },
      ),
    );
    overlay.insert(entry);

    if (startAfter != null) await startAfter;
    // Let the dashboard's first frames finish before anything moves.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    for (var i = 0; i < 90 && _active?._rect == null; i++) {
      await WidgetsBinding.instance.endOfFrame;
    }
    final target = _active;
    final rect = target?._rect;
    if (target == null || rect == null) {
      entry.remove();
      flying.value = false;
      progress.dispose();
      return;
    }
    toPos = rect.topLeft;
    toStyle = target.widget.style;

    final controller = AnimationController(vsync: overlay, duration: const Duration(milliseconds: 750));
    controller.addListener(() => progress.value = controller.value);
    await controller.forward();
    // Show the real text under the flying one, then drop the flying one.
    flying.value = false;
    await WidgetsBinding.instance.endOfFrame;
    entry.remove();
    controller.dispose();
    progress.dispose();
  }

  @override
  State<HomeNameHero> createState() => _HomeNameHeroState();
}

class _HomeNameHeroState extends State<HomeNameHero> {
  @override
  void initState() {
    super.initState();
    HomeNameHero._active = this;
  }

  @override
  void dispose() {
    if (HomeNameHero._active == this) HomeNameHero._active = null;
    super.dispose();
  }

  Rect? get _rect {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: HomeNameHero.flying,
      builder: (context, flying, child) => Opacity(opacity: flying ? 0 : 1, child: child),
      child: Text(widget.name, style: widget.style, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// The last step of first-run setup: the user names their home by typing
/// straight onto the page, in the middle of the screen, with no text box.
/// The name then flies up into the dashboard's header. Saved to the same
/// `nickname` pref Settings edits, so nothing else needs to know about it.
class NameHomeScreen extends StatefulWidget {
  /// Test Mode: looks and types like the real step but never saves or leaves.
  final bool preview;
  const NameHomeScreen({super.key, this.preview = false, this.skipLabel = 'Name it later'});

  /// Wording of the quiet link under the button that carries on without
  /// saving a name ("Keep current name" when switching device).
  final String skipLabel;

  @override
  State<NameHomeScreen> createState() => _NameHomeScreenState();
}

class _NameHomeScreenState extends State<NameHomeScreen> {
  static const List<String> _suggestions = ['Our Home', 'Bahay', 'Apartment'];

  /// Both the field and the flying name sit in a box this tall, so swapping
  /// one for the other doesn't move anything.
  static const double _nameBox = 64;

  final _controller = TextEditingController();
  final _nameKey = GlobalKey();
  bool _leaving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _typed => _controller.text.trim();

  /// What the headline shows: what is typed, else the name already in use.
  String get _shown => _typed.isEmpty ? nicknameNotifier.value : _typed;

  Future<void> _continue({required bool save}) async {
    if (_leaving || widget.preview) return;
    // The typed text becomes the flying name (same spot, same style).
    setState(() => _leaving = true);
    FocusManager.instance.primaryFocus?.unfocus();
    if (save && _typed.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('nickname', _typed);
      // Before the dashboard is built, so it opens with the new name.
      nicknameNotifier.value = _typed;
    }
    if (!mounted) return;
    final reduce = MediaQuery.disableAnimationsOf(context);
    // Let the rest of the page fade out so the name leaves on its own.
    if (!reduce) await Future<void>.delayed(const Duration(milliseconds: 260));
    if (!mounted) return;

    // The name leaves as a copy drawn above the route change, starting
    // exactly where the typed name sits, and lands on the dashboard's line.
    final box = _nameKey.currentContext?.findRenderObject();
    final overlay = Overlay.of(context, rootOverlay: true);
    final from = !reduce && box is RenderBox && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;

    // Two beats: the screens crossfade with the name holding still above
    // them, then (once the dashboard has settled) the name glides.
    final route = PageRouteBuilder<void>(
      transitionDuration: reduce ? Duration.zero : const Duration(milliseconds: 600),
      pageBuilder: (_, _, _) => const MainScreen(),
      transitionsBuilder: (context, animation, _, child) =>
          FadeTransition(opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut), child: child),
    );
    Navigator.of(context).pushAndRemoveUntil(route, (_) => false);

    if (from != null) {
      final settled = Completer<void>();
      final animation = route.animation;
      if (animation == null || animation.isCompleted) {
        settled.complete();
      } else {
        void onStatus(AnimationStatus status) {
          if (status == AnimationStatus.completed && !settled.isCompleted) settled.complete();
        }

        animation.addStatusListener(onStatus);
      }
      HomeNameHero.flyIn(
        overlay: overlay,
        name: _shown,
        from: from,
        fromStyle: _kDisplay,
        startAfter: settled.future.timeout(const Duration(seconds: 3), onTimeout: () {}),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    final fade = reduce ? Duration.zero : const Duration(milliseconds: 200);
    final opacity = _leaving ? 0.0 : 1.0;

    return PopScope(
      // Back skips the naming and carries on to the dashboard.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _continue(save: false);
      },
      child: SetupScaffold(
        showBack: false,
        body: Column(
          children: [
            // The middle of whatever room the keyboard leaves.
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: _nameBox,
                        child: _leaving
                            ? Center(
                                child: Text(_shown, key: _nameKey, style: _kDisplay, maxLines: 1, overflow: TextOverflow.ellipsis),
                              )
                            : Semantics(
                                textField: true,
                                label: 'Home name',
                                child: TextField(
                                  controller: _controller,
                                  autofocus: true,
                                  maxLength: 24,
                                  maxLines: 1,
                                  textAlign: TextAlign.center,
                                  textAlignVertical: TextAlignVertical.center,
                                  textCapitalization: TextCapitalization.words,
                                  textInputAction: TextInputAction.done,
                                  cursorColor: kSetupOnField,
                                  cursorWidth: 2.5,
                                  style: _kDisplay,
                                  decoration: InputDecoration(
                                    isCollapsed: true,
                                    border: InputBorder.none,
                                    counterText: '',
                                    hintText: nicknameNotifier.value,
                                    hintStyle: _kDisplay.copyWith(color: const Color(0x80FAFAFA)),
                                  ),
                                  onChanged: (_) => setState(() {}),
                                  onSubmitted: (_) => _typed.isEmpty ? null : _continue(save: true),
                                ),
                              ),
                      ),
                      AnimatedOpacity(
                        opacity: opacity,
                        duration: fade,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Just enough to show where the typing goes.
                            Container(height: 1.5, color: const Color(0x4DFAFAFA)),
                            const SizedBox(height: 20),
                            const Text(
                              'What should we call your home? It shows at the top of your dashboard.',
                              textAlign: TextAlign.center,
                              style: _kBody,
                            ),
                            const SizedBox(height: 24),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final s in _suggestions)
                                  _SuggestionPill(
                                    label: s,
                                    onTap: () => setState(() {
                                      _controller.text = s;
                                      _controller.selection = TextSelection.collapsed(offset: s.length);
                                    }),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedOpacity(
              opacity: opacity,
              duration: fade,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SetupPrimaryButton(
                      label: 'Go to Dashboard',
                      onPressed: _typed.isEmpty || _leaving ? null : () => _continue(save: true),
                    ),
                    const SizedBox(height: 4),
                    SetupTextLink(label: widget.skipLabel, onPressed: () => _continue(save: false)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _SuggestionPill({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const StadiumBorder(side: BorderSide(color: kSetupOnField, width: 1.5)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        splashColor: const Color(0x1FFAFAFA),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                style: const TextStyle(
                  fontFamily: kSetupFont,
                  fontSize: 13,
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                  color: kSetupOnField,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
