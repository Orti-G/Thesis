import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:esp_provisioning_ble/esp_provisioning_ble.dart';
import 'package:share_plus/share_plus.dart';

import '../device_id_screen.dart';
import '../disclaimer_dialog.dart';
import '../remote_reset.dart';
import 'ble_scanner.dart';
import 'intro_screens.dart';
import 'provisioning_service.dart';
import 'setup_ui.dart';

/// Route name for Find Device, so "Start Over" can pop back to it from
/// anywhere later in the flow instead of exiting setup entirely.
const String _kFindDeviceRoute = 'wifi-setup/find-device';

/// Route name for Get Ready, the first-run flow's bottom route — skipping
/// Wi-Fi pops back to it so the Bluetooth screens in between are disposed.
const String _kGetReadyRoute = 'wifi-setup/get-ready';

/// Entry point for the device setup flow. Test on a real phone — BLE does
/// not work in the iOS/Android simulators.
///
/// The flow follows the six stages the device's LCD shows, with the same
/// step numbers so a stuck user can be guided from either screen:
/// 1 pick the device → 2 pair → 3 paired (device ID received), choose
/// Wi-Fi → 4 connecting → 5 waiting for the device to come online →
/// 6 its Device ID, saved and ready to share.
///
/// [firstRun] is the onboarding call, which starts with Get Ready and
/// offers "Skip" to link an existing device by ID instead (viewers, or a
/// monitor that's already on Wi-Fi — those don't advertise over BLE, so
/// Get Ready tells the user to hold BOOT to put it back in setup mode).
///
/// Leave it false (the default) for the Settings "Set up / Reconfigure
/// Wi-Fi" entry point, which jumps straight to Find Device.
///
/// Returns once the flow's routes are gone — the Done screen pops back to
/// the first route, so the caller can re-read prefs afterwards.
Future<void> showWifiSetupFlow(BuildContext context, {bool firstRun = false, bool showIntro = false}) async {
  await Navigator.of(context).push(
    firstRun ? wifiSetupFirstRunRoute(showIntro: showIntro) : _findDeviceRoute(firstRun: false),
  );
}

/// The first-run entry route, so a caller can swap it in for another route
/// (the disclaimer modal does, to fade straight into the setup page).
///
/// [showIntro] puts the short intro (outcome, what matters, what you get)
/// ahead of Get Ready; it swaps itself for Get Ready, which stays the flow's
/// bottom route.
Route<void> wifiSetupFirstRunRoute({bool showIntro = false}) {
  if (!showIntro) return _getReadyRoute();
  // One route for both, so the caller's wait on this route spans the intro
  // and Get Ready; swapping routes would end it early.
  return setupRoute(name: _kGetReadyRoute, builder: (_) => const _IntroThenGetReady());
}

/// The intro, then Get Ready in the same route (a crossfade between them).
class _IntroThenGetReady extends StatefulWidget {
  const _IntroThenGetReady();

  @override
  State<_IntroThenGetReady> createState() => _IntroThenGetReadyState();
}

class _IntroThenGetReadyState extends State<_IntroThenGetReady> {
  bool _introDone = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 320),
      child: _introDone
          ? const _GetReadyScreen(key: ValueKey('get-ready'))
          : IntroScreen(key: const ValueKey('intro'), onDone: (_) => setState(() => _introDone = true)),
    );
  }
}

Route<void> _getReadyRoute() => setupRoute(name: _kGetReadyRoute, builder: (_) => const _GetReadyScreen());

Route<void> _findDeviceRoute({required bool firstRun}) {
  return setupRoute(
    name: _kFindDeviceRoute,
    builder: (_) => FindDeviceScreen(firstRun: firstRun),
  );
}

// ── CHANGE WI-FI (Settings, owner only) ────────────────────────────────────

/// Settings' "Change Wi-Fi" for the phone that set the monitor up: asks the
/// VM to make [deviceId] forget its Wi-Fi, waits for it to restart into
/// setup mode, then carries straight on into Find Device and the normal
/// reconfigure flow. Returns once the flow's routes are gone.
Future<void> showChangeWifiFlow(BuildContext context, String deviceId) async {
  await Navigator.of(context).push(
    // Named like Find Device and turning into it in place, so "Start Over"
    // finds it and the caller's wait spans the whole flow.
    setupRoute(name: _kFindDeviceRoute, builder: (_) => _RestartMonitorScreen(deviceId: deviceId)),
  );
}

enum _RestartPhase { sending, waiting, failed, restarted }

class _RestartMonitorScreen extends StatefulWidget {
  final String deviceId;

  /// Test Mode: hold this phase (and [previewError]) and never call the VM.
  final _RestartPhase? preview;
  final String? previewError;

  const _RestartMonitorScreen({required this.deviceId, this.preview, this.previewError});

  @override
  State<_RestartMonitorScreen> createState() => _RestartMonitorScreenState();
}

class _RestartMonitorScreenState extends State<_RestartMonitorScreen> {
  late _RestartPhase _phase = widget.preview ?? _RestartPhase.sending;
  late String? _error = widget.previewError;

  @override
  void initState() {
    super.initState();
    if (widget.preview == null) _run();
  }

  Future<void> _run() async {
    setState(() {
      _phase = _RestartPhase.sending;
      _error = null;
    });

    final response = await sendResetWifi(widget.deviceId);
    if (!mounted) return;
    if (response.result != RemoteResetResult.queued) {
      _fail(switch (response.result) {
        RemoteResetResult.notOwner => "This phone isn't the one that set up your monitor, so it can't reset it.",
        RemoteResetResult.noOwner => 'This monitor has no owner registered yet.',
        RemoteResetResult.conflict => response.message ?? "Your monitor can't be reset right now.",
        RemoteResetResult.notConfigured => "Remote reset isn't set up in this build of the app.",
        _ => "Couldn't send the reset. Check your connection and try again.",
      });
      return;
    }

    setState(() => _phase = _RestartPhase.waiting);
    final delivery = await watchResetDelivery(widget.deviceId);
    if (!mounted) return;
    switch (delivery) {
      case ResetDelivery.restarted:
        HapticFeedback.mediumImpact();
        setState(() => _phase = _RestartPhase.restarted);
      case ResetDelivery.offline:
        _fail("Your monitor was offline, so the reset didn't reach it.");
      case ResetDelivery.notDelivered:
        _fail("Your monitor didn't restart. Try again.");
    }
  }

  void _fail(String message) => setState(() {
    _phase = _RestartPhase.failed;
    _error = message;
  });

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduce ? Duration.zero : const Duration(milliseconds: 320),
      child: _phase == _RestartPhase.restarted
          ? const FindDeviceScreen(key: ValueKey('find'))
          : KeyedSubtree(key: const ValueKey('restart'), child: _buildRestart()),
    );
  }

  Widget _buildRestart() {
    final failed = _phase == _RestartPhase.failed;
    return SetupScaffold(
      title: failed ? "Couldn't restart your monitor" : 'Restarting your monitor',
      subtitle: failed ? null : 'Stay next to it. This usually takes under a minute.',
      content: [
        if (failed)
          SetupNotice(message: _error ?? "Something went wrong. Try again.", tone: SetupTone.danger)
        else
          SetupStatusLine(_phase == _RestartPhase.sending ? 'Sending the reset…' : 'Waiting for it to restart…'),
      ],
      bottom: failed
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SetupPrimaryButton(label: 'Try again', onPressed: widget.preview != null ? _noop : _run),
                const SizedBox(height: 4),
                SetupTextLink(
                  label: 'Close',
                  onPressed: widget.preview != null ? _noop : () => Navigator.of(context).maybePop(),
                ),
              ],
            )
          : null,
    );
  }
}

/// Matches the device LCD's "STEP n/6".
const int _kTotalSteps = 6;

/// Set by a later step right before it pops back to Find Device, so that
/// screen can say why and rescan.
class _ScanListReturn {
  final String? message;
  const _ScanListReturn(this.message);
}

final ValueNotifier<_ScanListReturn?> _scanListReturn = ValueNotifier(null);

/// Back to the device list (step 1), e.g. after a lost connection or a
/// failed Wi-Fi attempt — the device drops BLE and returns to its own
/// step 1 in those cases, so the old session can't be reused.
void _returnToScanList(BuildContext context, [String? message]) {
  _scanListReturn.value = _ScanListReturn(message);
  Navigator.of(context).popUntil(ModalRoute.withName(_kFindDeviceRoute));
}

/// First run only: jump past the Bluetooth and Wi-Fi steps straight to
/// linking a Device ID — for a viewer who was given one, a monitor that's
/// already on Wi-Fi, or to do Wi-Fi later from Settings.
/// Popping back to Get Ready first disposes the scanner and any open BLE
/// session on the screens in between; the Device ID is still required.
void _skipWifiSetup(BuildContext context) {
  final navigator = Navigator.of(context);
  navigator.popUntil(ModalRoute.withName(_kGetReadyRoute));
  navigator.push(setupRoute(builder: (_) => const _LinkDeviceScreen()));
}

/// The skip action for a screen: only on the first run. Settings'
/// reconfigure flow has no skip — Back already leaves it.
VoidCallback? _skipFor(BuildContext context, bool firstRun) => firstRun ? () => _skipWifiSetup(context) : null;

/// [button] with a "Skip Wi-Fi setup" link under it when [onSkip] is set.
Widget? _withSkip(VoidCallback? onSkip, [Widget? button, String label = 'Skip Wi-Fi setup']) {
  if (onSkip == null) return button;
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (button != null) ...[button, const SizedBox(height: 4)],
      SetupTextLink(label: label, onPressed: onSkip),
    ],
  );
}

/// "Skip to linking" as an off-white pill, so it reads as a button over the
/// illustration behind it: deep-orange label on off-white, like the setup
/// flow's other pills.
class _SkipPill extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const _SkipPill({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kSetupOnField,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
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
                  fontSize: 14,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: kSetupAccent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How big the get-ready illustrations are drawn, as a multiple of the page's
/// height. Both pages use the same value (and the same placement, below) so
/// the picture holds still while the pages slide past each other.
const double _kGetReadyArtScale = 1.2075;

/// How far the picture sinks, as a fraction of its own height: enough to
/// push a cut-off bottom edge in the exports off the screen.
const double _kGetReadyArtDrop = 0.03;

/// A get-ready page's illustration as the page's backdrop: drawn
/// [_kGetReadyArtScale] times the page height square (so wider than the
/// screen — its own margins run off the edges), anchored low, with the page's
/// content layered on top. Place it as the first child of a [Stack].
class _GetReadyArt extends StatelessWidget {
  final String asset;
  final double pageHeight;
  final double bottomInset;

  /// Hidden art keeps its place and its loaded animation (so it can be shown
  /// on a single frame) but is not drawn.
  final bool visible;

  /// Holds the animation on its first frame until true.
  final bool play;

  /// Changing this plays the animation again from the start.
  final int restart;

  const _GetReadyArt({
    required this.asset,
    required this.pageHeight,
    required this.bottomInset,
    this.visible = true,
    this.play = true,
    this.restart = 0,
  });

  @override
  Widget build(BuildContext context) {
    final side = pageHeight * _kGetReadyArtScale;
    return Positioned.fill(
      child: Visibility(
        visible: visible,
        maintainState: true,
        maintainAnimation: true,
        maintainSize: true,
        child: OverflowBox(
          alignment: Alignment.bottomCenter,
          minWidth: side,
          maxWidth: side,
          minHeight: side,
          maxHeight: side,
          child: FractionalTranslation(
            translation: const Offset(0, _kGetReadyArtDrop),
            child: Padding(
              padding: EdgeInsets.only(bottom: 8 + bottomInset),
              child: SetupLottie(asset: asset, alignment: Alignment.bottomCenter, play: play, restart: restart),
            ),
          ),
        ),
      ),
    );
  }
}

/// Slides [child] up into place from [distance] below when it first appears,
/// with a little overshoot before it settles. Just shows it under
/// reduce-motion.
class _RiseIn extends StatelessWidget {
  final double distance;
  final Widget child;
  const _RiseIn({required this.distance, required this.child});

  /// Fast out, then a few percent past the end and back.
  static const Curve _curve = Cubic(0.2, 0.9, 0.3, 1.12);

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 800),
      curve: _curve,
      builder: (context, t, child) => Transform.translate(offset: Offset(0, (1 - t) * distance), child: child),
      child: child,
    );
  }
}

/// Holds which file of the pairing animation is showing, so a caption drawn
/// elsewhere on the page can follow it.
class _PairGuideHost extends StatefulWidget {
  final Widget Function(BuildContext context, int step, ValueChanged<int> onStep) builder;
  const _PairGuideHost({required this.builder});

  @override
  State<_PairGuideHost> createState() => _PairGuideHostState();
}

class _PairGuideHostState extends State<_PairGuideHost> {
  int _step = 0;

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _step, (step) {
      if (mounted && step != _step) setState(() => _step = step);
    });
  }
}

/// The quiet label above the pairing-code box. Fades between its two texts.
class _PairCaption extends StatelessWidget {
  final int step;
  final String text;
  const _PairCaption({required this.step, required this.text});

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      height: 20,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: AnimatedSwitcher(
          duration: reduce ? Duration.zero : const Duration(milliseconds: 250),
          child: Text(
            text,
            key: ValueKey(step),
            textAlign: TextAlign.center,
            maxLines: 1,
            style: const TextStyle(
              fontFamily: kSetupFont,
              fontSize: 12,
              height: 1.3,
              letterSpacing: 1.6,
              fontWeight: FontWeight.w600,
              color: Color(0xE6FAFAFA),
            ),
          ),
        ),
      ),
    );
  }
}

/// Default for the views' callbacks, so the setup preview can leave them
/// out and every button still looks enabled.
void _noop() {}

// ── 0. GET READY (first run only) ──────────────────────────────────────────

/// Two swipeable intro pages before any scanning starts: a welcome with
/// the monitor photo, then a "before we start" checklist so the device and
/// the Wi-Fi password are at hand.
class _GetReadyScreen extends StatefulWidget {
  /// 0 = welcome, 1 = checklist. The setup preview opens either one.
  final int initialPage;

  /// Overrides leaving for Find Device / skipping to linking — the setup
  /// preview passes no-ops. Null keeps the real navigation.
  final VoidCallback? onContinue;
  final VoidCallback? onSkip;

  const _GetReadyScreen({super.key, this.initialPage = 0, this.onContinue, this.onSkip});

  @override
  State<_GetReadyScreen> createState() => _GetReadyScreenState();
}

class _GetReadyScreenState extends State<_GetReadyScreen> with SingleTickerProviderStateMixin {
  static const _pageCount = 2;

  /// The whole change of page: the old page's text slides away (first half),
  /// the picture changes in place at the midpoint with no movement, and the
  /// new page's text slides in (second half).
  late final AnimationController _swap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
    value: 1,
  )..addListener(_onSwapTick);

  /// The page whose text is on screen (and whose picture is shown).
  late int _page = widget.initialPage;
  int _target = 0;

  /// Bumped when a page's picture is shown again, so it plays from the start.
  final List<int> _artRounds = [0, 0];

  @override
  void initState() {
    super.initState();
    _target = _page;
  }

  @override
  void dispose() {
    _swap.dispose();
    super.dispose();
  }

  void _onSwapTick() {
    // Midpoint: the old text is gone, so change the page underneath it.
    if (_swap.value >= 0.5 && _page != _target) {
      setState(() => _showPage(_target));
    }
  }

  void _showPage(int page) {
    _page = page;
    _artRounds[page]++;
  }

  void _goTo(int page) {
    if (page == _page && !_swap.isAnimating) return;
    if (page < 0 || page >= _pageCount || _swap.isAnimating) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _showPage(page));
      return;
    }
    _target = page;
    _swap.forward(from: 0);
  }

  void _next() {
    if (_page < _pageCount - 1) {
      _goTo(_page + 1);
    } else if (widget.onContinue case final onContinue?) {
      onContinue();
    } else {
      Navigator.of(context).push(_findDeviceRoute(firstRun: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return PopScope(
      // Setup is required on first run — there's nothing behind this
      // screen to go back to. System back on the second page returns to
      // the first instead.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _page > 0) _goTo(_page - 1);
      },
      child: SetupScaffold(
        showBack: false,
        // The illustration runs off the bottom edge of the screen.
        bleedBottom: true,
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: (details) {
            final v = details.primaryVelocity ?? 0;
            if (v < -300) _goTo(_page + 1);
            if (v > 300) _goTo(_page - 1);
          },
          child: LayoutBuilder(
            builder: (context, box) => Stack(
              children: [
                // The pictures never move: both sit in the same place, and
                // changing page just swaps which one is drawn.
                _GetReadyArt(
                  asset: kSetupWelcomeLottie,
                  pageHeight: box.maxHeight,
                  bottomInset: bottomInset,
                  visible: _page == 0,
                  restart: _artRounds[0],
                ),
                _GetReadyArt(
                  asset: kSetupBeforeLottie,
                  pageHeight: box.maxHeight,
                  bottomInset: bottomInset,
                  visible: _page == 1,
                  play: _page == 1,
                  restart: _artRounds[1],
                ),
                AnimatedBuilder(
                  animation: _swap,
                  builder: (context, _) =>
                      _page == 0 ? _buildWelcome(_swap.value) : _buildChecklist(_swap.value, bottomInset),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Welcome: the headline slides up, the next button down.
  Widget _buildWelcome(double v) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SwapSlide(
          v: v,
          up: true,
          child: const Padding(
            padding: EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: SetupTitle(
              title: "Let's get your monitor online",
              subtitle: 'A few quick steps. About two minutes.',
            ),
          ),
        ),
        _SwapSlide(
          v: v,
          up: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            child: SetupSlideButton(label: 'Get started', onPressed: _next),
          ),
        ),
      ],
    );
  }

  /// Before we start: the title and checklist slide up, the bottom row down.
  Widget _buildChecklist(double v, double bottomInset) {
    return Column(
      children: [
        Expanded(
          child: _SwapSlide(
            v: v,
            up: true,
            child: const SetupPageBody(
              title: 'Before we start',
              subtitle: 'Have these ready. Set it up before? Hold its BOOT button for 3 seconds first.',
              content: [
                SetupChecklist(items: ['Monitor plugged in and lit', 'Bluetooth on', 'Your Wi-Fi password (2.4 GHz)']),
              ],
            ),
          ),
        ),
        // One quiet row instead of a full-width pill, so the illustration
        // behind stays clear: the skip link at the left, the round next
        // button at the right.
        _SwapSlide(
          v: v,
          up: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 16 + bottomInset),
            child: Row(
              children: [
                _SkipPill(label: 'Skip to linking', onPressed: widget.onSkip ?? () => _skipWifiSetup(context)),
                const Spacer(),
                SetupArrowButton(semanticLabel: "Let's go", onPressed: _next),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One half of the get-ready page change. [v] is the swap's progress, 0 to 1:
/// over the first half the child fades and slides away (up, or down when
/// [up] is false); over the second half the next page's child comes back the
/// way it left — the upper text down from above, the lower from below.
class _SwapSlide extends StatelessWidget {
  final double v;
  final bool up;
  final Widget child;
  const _SwapSlide({required this.v, required this.up, required this.child});

  static const double _distance = 56;

  @override
  Widget build(BuildContext context) {
    // 1 = in place and fully shown; 0 = gone.
    final shown = v < 0.5 ? 1 - Curves.easeInCubic.transform(v * 2) : Curves.easeOutCubic.transform((v - 0.5) * 2);
    return Opacity(
      opacity: shown,
      child: Transform.translate(offset: Offset(0, (up ? -1 : 1) * (1 - shown) * _distance), child: child),
    );
  }
}

// ── 1. FIND DEVICE ─────────────────────────────────────────────────────────

class FindDeviceScreen extends StatefulWidget {
  final bool firstRun;
  const FindDeviceScreen({super.key, this.firstRun = false});

  @override
  State<FindDeviceScreen> createState() => _FindDeviceScreenState();
}

class _FindDeviceScreenState extends State<FindDeviceScreen> with WidgetsBindingObserver {
  final _scanner = BleScanner();
  bool _autoScanStarted = false;

  /// Why a later step sent the user back here, e.g. "Connection lost."
  String? _returnNotice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scanListReturn.value = null;
    _scanListReturn.addListener(_onReturned);
    _scanner.init();
    _scanner.addListener(_onScannerUpdate);
  }

  void _onReturned() {
    final returned = _scanListReturn.value;
    if (returned == null || !mounted) return;
    setState(() => _returnNotice = returned.message);
    // The device list is stale by now (the unit may have rebooted).
    if (_scanner.isAdapterReady) _scanner.startScan();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from system settings: pick up a permission granted there.
    if (state == AppLifecycleState.resumed) _scanner.refreshPermissions();
  }

  void _onScannerUpdate() {
    // A denial stops the scan; arm the auto-start again so it begins by
    // itself once access is granted (here or in system settings).
    if (_scanner.permissionDenied) _autoScanStarted = false;
    // Start the scan as soon as Bluetooth is on and nothing is blocking it.
    if (_scanner.isAdapterReady && !_scanner.permissionDenied && !_autoScanStarted) {
      _autoScanStarted = true;
      _scanner.startScan();
    }
    if (mounted) setState(() {});
  }

  Future<void> _openDevice(ScanResult result) async {
    await _scanner.stopScan();
    if (!mounted) return;
    setState(() => _returnNotice = null);
    await Navigator.of(context).push(
      setupRoute(
        builder: (_) => ConnectScreen(device: result.device, firstRun: widget.firstRun),
      ),
    );
    // Plain Back from Pair: rescan. When Pair was replaced by the Wi-Fi
    // step this future also completes, but this screen isn't on top then
    // and scanning would compete with the open BLE session; returns from
    // later steps come through _onReturned instead.
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
    if (_scanner.isAdapterReady) _scanner.startScan();
  }

  @override
  void dispose() {
    _scanListReturn.removeListener(_onReturned);
    WidgetsBinding.instance.removeObserver(this);
    _scanner.removeListener(_onScannerUpdate);
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _scanner;
    final devices = s.devices;
    final status = s.isAdapterUnavailable
        ? _FindStatus.unavailable
        : s.permissionDenied
        ? _FindStatus.permission
        : !s.isAdapterReady || s.locationServicesOff
        ? _FindStatus.phoneNotReady
        : devices.isEmpty && s.isScanning
        ? _FindStatus.searching
        : devices.isEmpty
        ? _FindStatus.notFound
        : _FindStatus.found;

    return _FindDeviceView(
      status: status,
      onSkip: _skipFor(context, widget.firstRun),
      returnNotice: _returnNotice,
      onRescan: s.isAdapterReady && !s.isScanning ? s.startScan : null,
      onScanAgain: s.startScan,
      permissionPermanentlyDenied: s.permissionPermanentlyDenied,
      onOpenPermissionSettings: s.openPermissionSettings,
      // The scan then starts once, from _onScannerUpdate.
      onAllowAccess: s.requestAccess,
      bluetoothOn: s.isAdapterReady,
      canTurnOnBluetooth: s.canTurnOnFromApp,
      onTurnOnBluetooth: s.turnOnAdapter,
      locationNeeded: s.locationNeeded,
      // The check always reflects whether Location is really on.
      locationOn: s.locationOn && !s.locationServicesOff,
      onOpenLocationSettings: s.openLocationSettings,
      adapterError: s.adapterError,
      scanError: s.scanError,
      devices: [
        for (final result in devices)
          (name: _friendlyDeviceName(result), rssi: result.rssi, onTap: () => _openDevice(result)),
      ],
    );
  }
}

/// Which page Find Device shows, in priority order.
enum _FindStatus { unavailable, permission, phoneNotReady, searching, notFound, found }

typedef _FoundDevice = ({String name, int rssi, VoidCallback onTap});

/// Find Device's pages as plain UI: [FindDeviceScreen] fills it from the
/// live scanner, the setup preview from sample data.
class _FindDeviceView extends StatelessWidget {
  final _FindStatus status;
  final VoidCallback? onSkip;

  /// Why a later step sent the user back here, e.g. "Connection lost."
  final String? returnNotice;

  /// Header "Rescan"; null hides it (mid-scan, or Bluetooth off).
  final VoidCallback? onRescan;
  final VoidCallback onScanAgain;
  final bool permissionPermanentlyDenied;
  final VoidCallback onAllowAccess;
  final VoidCallback onOpenPermissionSettings;
  final bool bluetoothOn;
  final bool canTurnOnBluetooth;
  final VoidCallback onTurnOnBluetooth;
  final bool locationNeeded;
  final bool locationOn;
  final VoidCallback onOpenLocationSettings;
  final String? adapterError;
  final String? scanError;
  final List<_FoundDevice> devices;

  const _FindDeviceView({
    required this.status,
    this.onSkip,
    this.returnNotice,
    this.onRescan,
    this.onScanAgain = _noop,
    this.permissionPermanentlyDenied = false,
    this.onAllowAccess = _noop,
    this.onOpenPermissionSettings = _noop,
    this.bluetoothOn = true,
    this.canTurnOnBluetooth = true,
    this.onTurnOnBluetooth = _noop,
    this.locationNeeded = false,
    this.locationOn = true,
    this.onOpenLocationSettings = _noop,
    this.adapterError,
    this.scanError,
    this.devices = const [],
  });

  @override
  Widget build(BuildContext context) {
    const step = 1;
    const total = _kTotalSteps;
    final refresh = onRescan != null ? SetupHeaderAction(label: 'Rescan', onPressed: onRescan!) : null;
    final notice = returnNotice == null
        ? null
        : [SetupNotice(tone: SetupTone.danger, message: returnNotice!), const SizedBox(height: 24)];

    switch (status) {
      case _FindStatus.unavailable:
        return SetupScaffold(
          step: step,
          totalSteps: total,
          title: "Bluetooth isn't available",
          subtitle: "This phone can't use Bluetooth, which setup needs to reach the monitor. Try another phone.",
          bottom: _withSkip(onSkip),
        );

      case _FindStatus.permission:
        return SetupScaffold(
          step: step,
          totalSteps: total,
          title: 'Allow nearby access',
          subtitle:
              'The app needs permission to find your monitor nearby, '
              "including Location on some phones. It's only used during setup.",
          bottom: _withSkip(
            onSkip,
            permissionPermanentlyDenied
                ? SetupPrimaryButton(label: 'Open Settings', onPressed: onOpenPermissionSettings)
                : SetupPrimaryButton(label: 'Allow Access', onPressed: onAllowAccess),
          ),
        );

      // Bluetooth and (where the phone needs it) Location on one page, each
      // with its own status; the scan starts by itself once both are on.
      case _FindStatus.phoneNotReady:
        return SetupScaffold(
          step: step,
          totalSteps: total,
          title: 'Get your phone ready',
          subtitle: 'Your phone uses these to find and talk to the monitor during setup.',
          content: [
            SetupStatusList(
              children: [
                SetupStatusRow(
                  icon: Icons.bluetooth_rounded,
                  title: 'Bluetooth',
                  subtitle: bluetoothOn
                      ? 'On'
                      : canTurnOnBluetooth
                      ? 'Off. Needed to reach the monitor.'
                      : 'Off. Turn it on in Settings or Control Center.',
                  done: bluetoothOn,
                  actionLabel: 'Turn on',
                  onTap: canTurnOnBluetooth ? onTurnOnBluetooth : null,
                ),
                // Android 11 and older only (or a newer phone whose scan
                // reported that it needs Location).
                if (locationNeeded)
                  SetupStatusRow(
                    icon: Icons.location_on_outlined,
                    title: 'Location',
                    subtitle: locationOn ? 'On' : 'Off. Android needs it to find nearby devices.',
                    done: locationOn,
                    actionLabel: 'Turn on',
                    onTap: onOpenLocationSettings,
                  ),
              ],
            ),
            // Raw error from reading the Bluetooth state, if any — shown so a
            // phone that stays stuck here can be diagnosed.
            if (adapterError case final error?) ...[
              const SizedBox(height: 16),
              SetupNotice(message: 'Details: ${error.split('\n').first}'),
            ],
          ],
          bottom: _withSkip(onSkip),
        );

      case _FindStatus.searching:
        return SetupScaffold(
          step: step,
          totalSteps: total,
          title: 'Looking for your monitor…',
          subtitle: 'Hold your phone near it. Only monitors in setup mode show up.',
          content: [...?notice, const SetupStatusLine('Searching nearby…')],
          bottom: _withSkip(onSkip),
        );

      case _FindStatus.notFound:
        return SetupScaffold(
          step: step,
          totalSteps: total,
          trailing: refresh,
          title: "We couldn't find it yet",
          subtitle: "Try these, then we'll look again.",
          content: [
            ...?notice,
            if (scanError case final error?) ...[
              SetupNotice(tone: SetupTone.danger, message: "Couldn't scan: $error"),
              const SizedBox(height: 24),
            ],
            const SetupChecklist(
              items: [
                'Check that its screen is lit',
                'Set up before? Hold BOOT for 3 seconds',
                'Move within a few meters',
              ],
            ),
          ],
          bottom: _withSkip(onSkip, SetupPrimaryButton(label: 'Scan Again', onPressed: onScanAgain)),
        );

      case _FindStatus.found:
        return SetupScaffold(
          step: step,
          totalSteps: total,
          trailing: refresh,
          title: devices.length == 1 ? 'We found your monitor' : 'Which one is yours?',
          subtitle: 'Select the name shown on the device screen.',
          content: [
            ...?notice,
            SetupList(
              children: [
                for (final device in devices)
                  SetupListTile(
                    icon: Icons.developer_board_outlined,
                    title: device.name,
                    subtitle: 'Ready to set up',
                    trailing: _SignalIcon(rssi: device.rssi, wifi: false),
                    onTap: device.onTap,
                  ),
              ],
            ),
          ],
          bottom: _withSkip(onSkip),
        );
    }
  }
}

/// The full BLE name ("PROV_EM-1A2B"), exactly as the LCD shows it in
/// step 1, so the user can match the two.
String _friendlyDeviceName(ScanResult result) {
  var name = result.device.platformName;
  if (name.isEmpty) name = result.advertisementData.advName;
  return name.isEmpty ? 'Energy Monitor' : name;
}

// ── 2–3. PAIR, then trade IDs (secure session with the PoP) ────────────────

class ConnectScreen extends StatefulWidget {
  final BluetoothDevice device;
  final bool firstRun;
  const ConnectScreen({super.key, required this.device, this.firstRun = false});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  /// How long "Paired with PROV_EM-XXXX" stays up before the Wi-Fi list.
  static const _pairedPause = Duration(milliseconds: 1400);

  final _prov = ProvisioningService();
  final _popController = TextEditingController();
  // The code is read off the LCD of the device in the user's hand, so
  // there's no one to hide it from — show it so typos are easy to spot.
  bool _obscurePop = false;
  bool _handedOff = false;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _prov.addListener(_onStateChange);
    // No auto-connect: pairing only starts once the user submits the PoP
    // they read off the device's own LCD panel.
  }

  void _submit() {
    final pop = _popController.text.trim();
    if (pop.isEmpty) return;
    FocusScope.of(context).unfocus();
    _prov.connectAndEstablishSession(widget.device, pop: pop);
  }

  void _onStateChange() {
    if (!mounted || _leaving) return;
    switch (_prov.state) {
      case ProvState.paired:
        setState(() {});
        Future.delayed(_pairedPause, () {
          if (!mounted || _prov.state != ProvState.paired) return;
          _handedOff = true;
          Navigator.of(context).pushReplacement(
            setupRoute(
              builder: (_) => ChooseWifiScreen(prov: _prov, firstRun: widget.firstRun),
            ),
          );
        });
      case ProvState.keyMismatch:
        // Each monitor has its own code, so a typo is the usual cause.
        // The device keeps advertising after rejecting it, so stay here
        // and let the user retype; Pair reconnects from scratch.
        setState(() {});
      case ProvState.disconnected:
      case ProvState.failed:
        // The device drops BLE and goes back to its own step 1, so the
        // user starts again from the list.
        _leaving = true;
        _returnToScanList(context, _prov.errorMessage);
      default:
        setState(() {});
    }
  }

  @override
  void dispose() {
    _prov.removeListener(_onStateChange);
    _popController.dispose();
    // On success ChooseWifiScreen owns _prov and disposes it. If the user
    // backs out instead, drop the BLE link here so the device isn't left
    // holding a half-open connection that blocks the next attempt.
    if (!_handedOff) _prov.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _prov.state;
    var deviceName = widget.device.platformName;
    if (deviceName.isEmpty) deviceName = widget.device.advName;

    return _PairView(
      deviceName: deviceName,
      controller: _popController,
      obscure: _obscurePop,
      onToggleObscure: () => setState(() => _obscurePop = !_obscurePop),
      onChanged: (_) => setState(() {}), // refresh button enabled-state
      onSubmit: _submit,
      onSkip: _skipFor(context, widget.firstRun),
      loading:
          state == ProvState.connecting ||
          state == ProvState.sessionEstablishing ||
          state == ProvState.exchangingSetupId,
      wrongCode: state == ProvState.keyMismatch,
      paired: state == ProvState.paired,
    );
  }
}

/// Steps 2–3 as plain UI: the pairing-code entry, then "Paired with …".
class _PairView extends StatelessWidget {
  /// The BLE name, or empty when the phone didn't get one.
  final String deviceName;
  final TextEditingController controller;
  final bool obscure;
  final VoidCallback onToggleObscure;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmit;
  final VoidCallback? onSkip;
  final bool loading;
  final bool wrongCode;
  final bool paired;

  const _PairView({
    required this.deviceName,
    required this.controller,
    this.obscure = false,
    this.onToggleObscure = _noop,
    required this.onChanged,
    this.onSubmit = _noop,
    this.onSkip,
    this.loading = false,
    this.wrongCode = false,
    this.paired = false,
  });

  @override
  Widget build(BuildContext context) {
    final isLoading = loading;
    final codeSource = deviceName.isEmpty ? "the monitor's screen" : "$deviceName's screen";

    if (paired) {
      return SetupScaffold(
        step: 3,
        totalSteps: _kTotalSteps,
        showBack: false,
        title: deviceName.isEmpty ? 'Paired' : 'Paired with $deviceName',
        subtitle: 'Next, pick the Wi-Fi it should join.',
        content: const [SetupNotice(tone: SetupTone.success, message: 'Secure connection set up')],
      );
    }

    return SetupScaffold(
      step: 2,
      totalSteps: _kTotalSteps,
      // Three layers: the animation at the back, drawn large; the title on
      // top of it at the top of the page; and the code box on top of it at
      // the bottom, just above the Pair button. Nothing competes with the
      // picture for room, and nothing scrolls. (The title only scrolls if the
      // keyboard leaves it too little room.) The animation goes file 1, then
      // file 2 in the same spot, then round again, resting three seconds on
      // each so the caption above the code box can be read.
      body: _PairGuideHost(
        builder: (context, step, onStep) => LayoutBuilder(
          builder: (context, box) {
            // Taller than the page is wide: the illustration's own margins run
            // off the screen edges, so the picture itself reads big.
            final side = box.maxHeight * 0.945;
            return Stack(
              children: [
                // No animation while pairing: it belongs to code entry only.
                if (!isLoading)
                  Positioned.fill(
                    // Comes up from below the screen when the page opens,
                    // with a little overshoot.
                    child: _RiseIn(
                      distance: side,
                      // Sat low: bottom-aligned, then eased down a further
                      // tenth of its own height so the picture sits below the
                      // title.
                      child: OverflowBox(
                        alignment: Alignment.bottomCenter,
                        minWidth: side,
                        maxWidth: side,
                        minHeight: side,
                        maxHeight: side,
                        child: FractionalTranslation(
                          translation: const Offset(0, 0.1),
                          // One animation in two files: 1 plays and rests,
                          // then 2 takes over in the same place and size and
                          // rests too, and it goes round again.
                          child: SetupLottieSequence(
                            assets: const [kSetupCodeLottieA, kSetupCodeLottieB],
                            loop: true,
                            holdAfterEach: const Duration(seconds: 3),
                            // Waits for the rise-in to settle before it plays.
                            startDelay: const Duration(milliseconds: 650),
                            onStepChanged: onStep,
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                    child: SetupTitle(
                      title: isLoading ? 'Pairing…' : 'Enter the pairing code',
                      subtitle: isLoading
                          ? 'Keep your phone near the monitor.'
                          : deviceName.isEmpty
                          ? "Each monitor has its own code. It's on your monitor's screen."
                          : "Each monitor has its own code. Use the one on $deviceName's screen.",
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // What the animation is pointing at right now: its first
                        // half the pairing code, its second the monitor's name.
                        // Hidden (but holding its space) while pairing.
                        Opacity(
                          opacity: isLoading ? 0 : 1,
                          child: _PairCaption(
                            step: step,
                            // The labels the monitor's own screen uses for each.
                            text: step == 0 ? 'PAIRING CODE' : 'DEVICE NAME',
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: controller,
                          obscureText: obscure,
                          autocorrect: false,
                          enableSuggestions: false,
                          enabled: !isLoading,
                          textAlign: TextAlign.center,
                          style: kSetupCodeTextStyle,
                          decoration: setupInputDecoration(
                            label: 'Pairing code',
                            errorText: wrongCode
                                ? "That code didn't match. Check $codeSource and try again — capital letters count."
                                : null,
                            suffixIcon: IconButton(
                              tooltip: obscure ? 'Show code' : 'Hide code',
                              icon: Icon(
                                obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                                color: kSetupMuted,
                              ),
                              onPressed: onToggleObscure,
                            ),
                          ),
                          onChanged: onChanged,
                          onSubmitted: (_) => onSubmit(),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
      // The same height in every state, so the page body — and with it the
      // animation sized from it — never changes size between "Enter the
      // pairing code" and "Pairing…". While pairing, the skip link keeps its
      // space but is hidden and inert.
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SetupPrimaryButton(
            label: isLoading || !wrongCode ? 'Pair' : 'Try Again',
            loading: isLoading,
            onPressed: isLoading || controller.text.trim().isEmpty ? null : onSubmit,
          ),
          if (onSkip != null) ...[
            const SizedBox(height: 4),
            Opacity(
              opacity: isLoading ? 0 : 1,
              child: IgnorePointer(
                ignoring: isLoading,
                child: ExcludeSemantics(
                  excluding: isLoading,
                  child: SetupTextLink(label: 'Skip Wi-Fi setup', onPressed: onSkip!),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── 3–5. CHOOSE WI-FI, then progress inline ────────────────────────────────

class ChooseWifiScreen extends StatefulWidget {
  final ProvisioningService prov;
  final bool firstRun;
  const ChooseWifiScreen({super.key, required this.prov, this.firstRun = false});

  @override
  State<ChooseWifiScreen> createState() => _ChooseWifiScreenState();
}

class _ChooseWifiScreenState extends State<ChooseWifiScreen> {
  bool _leaving = false;
  String? _pendingSsid;

  @override
  void initState() {
    super.initState();
    widget.prov.addListener(_onUpdate);
    widget.prov.scanWifi();
  }

  void _onUpdate() {
    if (!mounted || _leaving) return;
    final prov = widget.prov;
    switch (prov.state) {
      case ProvState.online:
        _leaving = true;
        Navigator.of(context).pushReplacement(
          setupRoute(
            builder: (_) => _DeviceReadyScreen(deviceId: prov.deviceId!, firstRun: widget.firstRun),
          ),
        );
      case ProvState.wifiFailed:
      case ProvState.disconnected:
      case ProvState.failed:
        // Wrong password, no IP, or BLE gone: the device restarts into
        // setup mode (or waits on its own screen), so the session can't be
        // reused — start again from the device list.
        _leaving = true;
        _returnToScanList(context, prov.errorMessage);
      default:
        setState(() {});
    }
  }

  @override
  void dispose() {
    widget.prov.removeListener(_onUpdate);
    widget.prov.dispose();
    super.dispose();
  }

  void _send(String ssid, String password, {String? bssid}) {
    setState(() => _pendingSsid = ssid);
    widget.prov.sendConfig(ssid, password, bssid: bssid);
  }

  Future<void> _connectTo(WifiAP network) async {
    if (!network.private) {
      _send(network.ssid, '', bssid: network.bssid);
      return;
    }
    final password = await _WifiPasswordSheet.show(context, ssid: network.ssid);
    if (password != null) _send(network.ssid, password, bssid: network.bssid);
  }

  Future<void> _addHiddenNetwork() async {
    final entry = await _HiddenNetworkSheet.show(context);
    if (entry != null) _send(entry.ssid, entry.password);
  }

  bool get _isBusy => switch (widget.prov.state) {
    ProvState.configSending || ProvState.polling || ProvState.waitingForSync || ProvState.online => true,
    _ => false,
  };

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Leaving while the device is applying credentials would drop the BLE
      // session mid-handshake and leave the device in an unknown state.
      canPop: !_isBusy,
      child: _buildPage(),
    );
  }

  Widget _buildPage() {
    final prov = widget.prov;
    final phase = switch (prov.state) {
      ProvState.scanningWifi => _WifiPhase.scanning,
      ProvState.wifiReady => _WifiPhase.list,
      ProvState.configSending || ProvState.polling => _WifiPhase.connecting,
      ProvState.waitingForSync => _WifiPhase.waitingForSync,
      ProvState.syncTimeout => _WifiPhase.syncTimeout,
      _ => _WifiPhase.leaving,
    };

    return _ChooseWifiView(
      phase: phase,
      onSkip: _skipFor(context, widget.firstRun),
      networks: [
        if (phase == _WifiPhase.list)
          for (final network in _dedupedNetworks(prov.wifiNetworks))
            (ssid: network.ssid, rssi: network.rssi, private: network.private, onTap: () => _connectTo(network)),
      ],
      errorMessage: prov.errorMessage,
      pendingSsid: _pendingSsid,
      onRescan: prov.scanWifi,
      onAddHidden: _addHiddenNetwork,
      onKeepWaiting: prov.keepWaitingForSync,
      onStartOver: () => _returnToScanList(context),
    );
  }
}

/// Which page Choose Wi-Fi shows; [leaving] is the blank frame while a
/// finished or failed attempt swaps the route out.
enum _WifiPhase { scanning, list, connecting, waitingForSync, syncTimeout, leaving }

typedef _WifiNetwork = ({String ssid, int rssi, bool private, VoidCallback onTap});

/// Steps 3–5 as plain UI: the network list, then connecting progress.
class _ChooseWifiView extends StatelessWidget {
  final _WifiPhase phase;
  final VoidCallback? onSkip;

  /// Already deduped and sorted strongest first.
  final List<_WifiNetwork> networks;
  final String? errorMessage;
  final String? pendingSsid;
  final VoidCallback onRescan;
  final VoidCallback onAddHidden;
  final VoidCallback onKeepWaiting;
  final VoidCallback onStartOver;

  const _ChooseWifiView({
    required this.phase,
    this.onSkip,
    this.networks = const [],
    this.errorMessage,
    this.pendingSsid,
    this.onRescan = _noop,
    this.onAddHidden = _noop,
    this.onKeepWaiting = _noop,
    this.onStartOver = _noop,
  });

  @override
  Widget build(BuildContext context) {
    switch (phase) {
      case _WifiPhase.scanning:
        return SetupScaffold(
          step: 3,
          totalSteps: _kTotalSteps,
          title: 'Looking for Wi-Fi…',
          subtitle: 'Your monitor is checking which networks it can reach.',
          content: const [SetupStatusLine('Scanning…')],
          bottom: _withSkip(onSkip),
        );

      case _WifiPhase.list:
        final refresh = SetupHeaderAction(label: 'Rescan', onPressed: onRescan);
        final error = errorMessage != null ? SetupNotice(tone: SetupTone.danger, message: errorMessage!) : null;

        if (networks.isEmpty) {
          return SetupScaffold(
            step: 3,
            totalSteps: _kTotalSteps,
            trailing: refresh,
            title: 'No networks found',
            subtitle: 'Move the monitor closer to your router, or enter a hidden network by name.',
            content: [?error],
            bottom: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SetupPrimaryButton(label: 'Scan Again', onPressed: onRescan),
                const SizedBox(height: 8),
                SetupSecondaryButton(label: 'Enter Network Manually', onPressed: onAddHidden),
                ?_withSkip(onSkip),
              ],
            ),
          );
        }

        return SetupScaffold(
          step: 3,
          totalSteps: _kTotalSteps,
          trailing: refresh,
          title: 'Which Wi-Fi should it join?',
          subtitle: "Only 2.4 GHz networks show up here. The monitor can't join 5 GHz.",
          content: [
            if (error != null) ...[error, const SizedBox(height: 24)],
            SetupList(
              children: [
                for (final network in networks)
                  SetupListTile(
                    icon: _signalIconData(network.rssi, wifi: true),
                    title: network.ssid,
                    subtitle: '${_signalLabel(network.rssi)} · ${network.private ? 'Secured' : 'Open'}',
                    onTap: network.onTap,
                  ),
                SetupListTile(
                  icon: Icons.add_rounded,
                  muted: true,
                  title: 'Enter network manually',
                  subtitle: 'For hidden networks',
                  onTap: onAddHidden,
                ),
              ],
            ),
          ],
          bottom: _withSkip(onSkip),
        );

      case _WifiPhase.connecting:
        return SetupScaffold(
          step: 4,
          totalSteps: _kTotalSteps,
          showBack: false,
          title: pendingSsid != null ? 'Connecting to $pendingSsid…' : 'Connecting to Wi-Fi…',
          subtitle: 'Hang tight, this usually takes under 30 seconds.',
          content: const [SetupStatusLine('Connecting…')],
        );

      case _WifiPhase.waitingForSync:
        return SetupScaffold(
          step: 5,
          totalSteps: _kTotalSteps,
          showBack: false,
          title: 'Connected to Wi-Fi',
          subtitle: 'Waiting for your monitor to come online. This can take up to a minute.',
          content: const [SetupStatusLine('Bringing it online…')],
        );

      case _WifiPhase.syncTimeout:
        return SetupScaffold(
          step: 5,
          totalSteps: _kTotalSteps,
          showBack: false,
          title: "Can't reach the server",
          subtitle:
              "${errorMessage ?? "Device joined Wi-Fi but can't reach the server."} "
              'Check that this Wi-Fi has internet access.',
          bottom: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SetupPrimaryButton(label: 'Keep Waiting', onPressed: onKeepWaiting),
              const SizedBox(height: 8),
              SetupSecondaryButton(label: 'Start Over', onPressed: onStartOver),
            ],
          ),
        );

      case _WifiPhase.leaving:
        // online / failure states: a brief frame before _onUpdate swaps
        // this route out.
        return const Scaffold(backgroundColor: kSetupBg);
    }
  }
}

/// The device reports one entry per access point, so mesh/extender setups
/// list the same SSID several times. Keep the strongest of each, drop
/// blank (hidden) SSIDs, and sort strongest first.
List<WifiAP> _dedupedNetworks(List<WifiAP> networks) {
  final bySsid = <String, WifiAP>{};
  for (final n in networks) {
    if (n.ssid.isEmpty) continue;
    final existing = bySsid[n.ssid];
    if (existing == null || n.rssi > existing.rssi) bySsid[n.ssid] = n;
  }
  return bySsid.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
}

// ── 6. DEVICE ID ───────────────────────────────────────────────────────────

/// The device is online and its ID is saved. The ID matches the one on the
/// LCD; sharing it lets others view this monitor by linking the same ID.
class _DeviceReadyScreen extends StatelessWidget {
  final String deviceId;
  final bool firstRun;

  /// Test Mode: the button does nothing instead of leaving the preview.
  final bool preview;
  const _DeviceReadyScreen({required this.deviceId, required this.firstRun, this.preview = false});

  void _finish(BuildContext context) {
    if (preview) return;
    // First run: name the home, which then flies into the dashboard.
    // Otherwise back to whatever launched the flow (Settings just reappears).
    if (firstRun) {
      Navigator.of(context).pushReplacement(setupRoute(builder: (_) => const NameHomeScreen()));
    } else {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: deviceId));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Device ID copied')));
  }

  void _share() {
    SharePlus.instance.share(ShareParams(text: 'Use this Device ID to view my KURO energy monitor: $deviceId'));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      // System back acts like the button instead of returning into a
      // finished flow.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish(context);
      },
      child: SetupScaffold(
        step: 6,
        totalSteps: _kTotalSteps,
        showBack: false,
        title: 'Your monitor is online',
        subtitle: 'This is its Device ID, the same one on its screen. Share it to add viewers.',
        content: [
          Semantics(
            label: 'Device ID $deviceId',
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 24),
              decoration: BoxDecoration(color: kSetupPanel, borderRadius: BorderRadius.circular(20)),
              child: ExcludeSemantics(
                child: SelectableText(
                  deviceId,
                  textAlign: TextAlign.center,
                  style: kSetupCodeTextStyle.copyWith(fontSize: 30),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SetupList(
            children: [
              SetupListTile(icon: Icons.copy_rounded, title: 'Copy Device ID', onTap: () => _copy(context)),
              SetupListTile(
                icon: Icons.ios_share_rounded,
                title: 'Share to add viewers',
                subtitle: 'They can watch live readings with it',
                onTap: _share,
              ),
            ],
          ),
        ],
        bottom: SetupPrimaryButton(label: firstRun ? 'Name your home' : 'Done', onPressed: () => _finish(context)),
      ),
    );
  }
}

// ── LINK BY DEVICE ID (first run, skip path) ───────────────────────────────

/// For a viewer who was given an ID, or a monitor that's already set up:
/// no BLE involved, just check the ID exists in Firebase and save it.
class _LinkDeviceScreen extends StatelessWidget {
  final DeviceIdPreview? preview;
  const _LinkDeviceScreen({this.preview});

  @override
  Widget build(BuildContext context) {
    return DeviceIdStep(
      preview: preview,
      showBack: true,
      title: 'Link your monitor',
      subtitle: 'Type the Device ID from its screen, or one someone shared with you.',
      onLinked: () => Navigator.of(context).pushReplacement(setupRoute(builder: (_) => const _SetupDoneScreen())),
    );
  }
}

// ── DONE (skip path) ───────────────────────────────────────────────────────

class _SetupDoneScreen extends StatelessWidget {
  /// Test Mode: the button does nothing instead of leaving the preview.
  final bool preview;
  const _SetupDoneScreen({this.preview = false});

  void _finish(BuildContext context) {
    if (preview) return;
    // Name the home next; that step hands over to the dashboard.
    Navigator.of(context).pushReplacement(setupRoute(builder: (_) => const NameHomeScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      // System back acts like the button instead of returning into a
      // finished flow.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish(context);
      },
      child: SetupScaffold(
        showBack: false,
        hero: const SetupCelebration(),
        heroAbove: true,
        title: "You're all set",
        subtitle: 'Your monitor is linked. If it still needs Wi-Fi, set it up in Settings so live readings come in.',
        bottom: SetupPrimaryButton(label: 'Name your home', onPressed: () => _finish(context)),
      ),
    );
  }
}

// ── Small shared widgets ────────────────────────────────────────────────────

/// Signal bars instead of raw dBm. Thresholds are the usual rough BLE/Wi-Fi
/// buckets: ≥ -60 strong, ≥ -75 fair, below that weak.
String _signalLabel(int rssi) => rssi >= -60
    ? 'Strong signal'
    : rssi >= -75
    ? 'Fair signal'
    : 'Weak signal';

IconData _signalIconData(int rssi, {required bool wifi}) {
  // All three Wi-Fi levels come from the same filled-fan family, so rows
  // differ only in how much of the fan is filled — the plain wifi_1_bar
  // icon is a lone dot that doesn't read as Wi-Fi at all.
  if (rssi >= -60) return wifi ? Icons.signal_wifi_4_bar_rounded : Icons.signal_cellular_alt_rounded;
  if (rssi >= -75) return wifi ? Icons.network_wifi_3_bar_rounded : Icons.signal_cellular_alt_2_bar_rounded;
  return wifi ? Icons.network_wifi_1_bar_rounded : Icons.signal_cellular_alt_1_bar_rounded;
}

class _SignalIcon extends StatelessWidget {
  final int rssi;
  final bool wifi;
  const _SignalIcon({required this.rssi, required this.wifi});

  @override
  Widget build(BuildContext context) {
    return Icon(
      _signalIconData(rssi, wifi: wifi),
      size: 20,
      color: kSetupMuted,
      semanticLabel: _signalLabel(rssi),
    );
  }
}

class _WifiPasswordSheet extends StatefulWidget {
  final String ssid;
  const _WifiPasswordSheet({required this.ssid});

  static Future<String?> show(BuildContext context, {required String ssid}) {
    return showSetupSheet<String>(
      context,
      title: ssid,
      subtitle: 'Enter the Wi-Fi password',
      builder: (_) => _WifiPasswordSheet(ssid: ssid),
    );
  }

  @override
  State<_WifiPasswordSheet> createState() => _WifiPasswordSheetState();
}

class _WifiPasswordSheetState extends State<_WifiPasswordSheet> {
  final _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_controller.text.isEmpty) return;
    Navigator.pop(context, _controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          obscureText: _obscure,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.password],
          style: const TextStyle(fontSize: 16, color: kSetupInk),
          decoration: setupInputDecoration(
            label: 'Password',
            suffixIcon: IconButton(
              tooltip: _obscure ? 'Show password' : 'Hide password',
              icon: Icon(_obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: kSetupMuted),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 20),
        SetupPrimaryButton(label: 'Connect', onPressed: _controller.text.isEmpty ? null : _submit),
      ],
    );
  }
}

class _HiddenNetworkEntry {
  final String ssid;
  final String password;
  const _HiddenNetworkEntry(this.ssid, this.password);
}

/// Hidden networks take the name and password on one sheet, instead of a
/// name dialog followed by a separate password prompt.
class _HiddenNetworkSheet extends StatefulWidget {
  const _HiddenNetworkSheet();

  static Future<_HiddenNetworkEntry?> show(BuildContext context) {
    return showSetupSheet<_HiddenNetworkEntry>(
      context,
      title: 'Hidden network',
      subtitle: 'Enter the exact network name and password',
      builder: (_) => const _HiddenNetworkSheet(),
    );
  }

  @override
  State<_HiddenNetworkSheet> createState() => _HiddenNetworkSheetState();
}

class _HiddenNetworkSheetState extends State<_HiddenNetworkSheet> {
  final _ssidController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _ssidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool get _canSubmit => _ssidController.text.trim().isNotEmpty;

  void _submit() {
    if (!_canSubmit) return;
    Navigator.pop(context, _HiddenNetworkEntry(_ssidController.text.trim(), _passwordController.text));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ssidController,
          autofocus: true,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          style: const TextStyle(fontSize: 16, color: kSetupInk),
          decoration: setupInputDecoration(label: 'Network name (SSID)'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontSize: 16, color: kSetupInk),
          decoration: setupInputDecoration(
            label: 'Password',
            hint: 'Leave empty for an open network',
            suffixIcon: IconButton(
              tooltip: _obscure ? 'Show password' : 'Hide password',
              icon: Icon(_obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: kSetupMuted),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 20),
        SetupPrimaryButton(label: 'Connect', onPressed: _canSubmit ? _submit : null),
      ],
    );
  }
}

// ── Setup preview (Test Mode) ───────────────────────────────────────────────

/// One page of the Test Mode setup preview: a real setup screen in one of
/// its states, built from sample data with inert buttons. [builder] gets a
/// `restart` callback that rebuilds the page from scratch (the disclaimer
/// uses it after its exit animation).
class SetupPreviewPage {
  final String group;
  final String label;
  final Widget Function(BuildContext context, VoidCallback restart) builder;

  /// What this page's animation should show (the animation section only).
  final String? note;

  const SetupPreviewPage(this.group, this.label, this.builder, {this.note});

  /// This page again, for the "needs animation" section.
  SetupPreviewPage needsAnimation(String note) => SetupPreviewPage(kNeedsAnimationGroup, label, builder, note: note);
}

const List<_FoundDevice> _kPreviewDevices = [
  (name: 'PROV_EM-1A2B', rssi: -52, onTap: _noop),
  (name: 'PROV_EM-7F3C', rssi: -71, onTap: _noop),
];

const List<_WifiNetwork> _kPreviewNetworks = [
  (ssid: 'HomeNet', rssi: -48, private: true, onTap: _noop),
  (ssid: 'HomeNet_Guest', rssi: -63, private: false, onTap: _noop),
  (ssid: 'PLDTHOMEFIBR_2.4G', rssi: -70, private: true, onTap: _noop),
  (ssid: 'Neighbor', rssi: -82, private: true, onTap: _noop),
];

const String _kPreviewDeviceName = 'PROV_EM-1A2B';

/// The preview's two sections, each stepped through on its own:
/// [flow] is every first-run setup page in order; [animation] is the
/// subset that should get a monitor animation, each with a note on what.
typedef SetupPreviewSections = ({List<SetupPreviewPage> flow, List<SetupPreviewPage> animation});

/// Group name of the "needs animation" section.
const String kNeedsAnimationGroup = 'Needs animation';

/// Every setup preview page, built from the same widgets the real flow
/// uses — so an edit to a screen shows up here too.
SetupPreviewSections setupPreviewSections() {
  Widget find(
    _FindStatus status, {
    bool permanentlyDenied = false,
    String? notice,
    List<_FoundDevice> devices = const [],
  }) {
    return _FindDeviceView(
      status: status,
      onSkip: _noop,
      returnNotice: notice,
      onRescan: status == _FindStatus.searching ? null : _noop,
      permissionPermanentlyDenied: permanentlyDenied,
      bluetoothOn: false,
      locationNeeded: true,
      locationOn: false,
      devices: devices,
    );
  }

  Widget wifi(_WifiPhase phase, {List<_WifiNetwork> networks = _kPreviewNetworks, String? error}) {
    return _ChooseWifiView(
      phase: phase,
      onSkip: _noop,
      networks: networks,
      errorMessage: error,
      pendingSsid: 'HomeNet',
    );
  }

  final searching = SetupPreviewPage('1 · Find device', 'Searching', (_, _) => find(_FindStatus.searching));
  final notFound = SetupPreviewPage('1 · Find device', 'Not found', (_, _) => find(_FindStatus.notFound));
  final enterCode = SetupPreviewPage('2 · Pair', 'Enter code', (_, _) => const _PreviewPair());
  final pairing = SetupPreviewPage('2 · Pair', 'Pairing', (_, _) => const _PreviewPair(code: 'A7K2Q9', loading: true));
  final connecting = SetupPreviewPage('4 · Connect', 'Connecting', (_, _) => wifi(_WifiPhase.connecting));
  final waiting = SetupPreviewPage('5 · Online', 'Waiting for monitor', (_, _) => wifi(_WifiPhase.waitingForSync));
  final monitorOnline = SetupPreviewPage(
    '6 · Device ID',
    'Monitor online',
    (_, _) => const _DeviceReadyScreen(deviceId: 'K7QM-4XPD', firstRun: true, preview: true),
  );
  final linkMonitor = SetupPreviewPage(
    'Skip path',
    'Link monitor',
    (_, _) => const _LinkDeviceScreen(preview: DeviceIdPreview.empty),
  );

  final flow = [
    // Dummy page for trying the soft background shapes before they go on
    // the real screens.
    for (final (style, name) in const [
      (0, 'Background shapes (approved)'),
      (1, 'Background shapes · 2 grid'),
      (2, 'Background shapes · 3 signal'),
      (3, 'Background shapes · 4 pebbles'),
      (4, 'Background shapes · 5 tide'),
      (5, 'Background shapes · 6 orbit'),
      (6, 'Background shapes · 7 stacks'),
      (7, 'Background shapes · 8 dunes'),
      (8, 'Background shapes · 9 bloom'),
      (9, 'Background shapes · 10 drift'),
    ])
      SetupPreviewPage(
        'Backdrop test',
        name,
        (_, _) => SetupScaffold(
          backdrop: true,
          backdropStyle: style,
          drift: true,
          showBack: false,
          step: 2,
          totalSteps: 6,
          title: 'Your monitor, ready to connect',
          subtitle: 'A few quick steps and your GRID monitor will be online.',
          bottom: SetupPrimaryButton(label: 'Continue', onPressed: _noop),
        ),
      ),
    SetupPreviewPage(
      'Intro',
      'Disclaimer',
      // Shown over the intro video's last frame, behind the dialog barrier.
      (_, restart) => ColoredBox(
        color: Colors.black,
        child: ColoredBox(
          color: Colors.black54,
          child: DisclaimerDialog(onAccepted: restart),
        ),
      ),
    ),
    for (final (page, name) in const [
      (0, 'Greeting'),
      (1, 'See it live'),
      (2, 'Know your bill'),
      (3, 'Catch the unusual'),
    ])
      SetupPreviewPage(
        'Intro',
        name,
        (_, _) => IntroScreen(initialPage: page, preview: true, onDone: (_) {}),
      ),
    SetupPreviewPage('Get ready', 'Welcome', (_, _) => const _GetReadyScreen(onContinue: _noop, onSkip: _noop)),
    SetupPreviewPage(
      'Get ready',
      'Before we start',
      (_, _) => const _GetReadyScreen(initialPage: 1, onContinue: _noop, onSkip: _noop),
    ),
    SetupPreviewPage('1 · Find device', 'Bluetooth unavailable', (_, _) => find(_FindStatus.unavailable)),
    SetupPreviewPage('1 · Find device', 'Allow access', (_, _) => find(_FindStatus.permission)),
    SetupPreviewPage(
      '1 · Find device',
      'Allow access (blocked)',
      (_, _) => find(_FindStatus.permission, permanentlyDenied: true),
    ),
    SetupPreviewPage('1 · Find device', 'Phone not ready', (_, _) => find(_FindStatus.phoneNotReady)),
    searching,
    SetupPreviewPage(
      '1 · Find device',
      'Searching after lost connection',
      (_, _) => find(_FindStatus.searching, notice: 'Connection to the monitor was lost.'),
    ),
    notFound,
    SetupPreviewPage(
      '1 · Find device',
      'Found one',
      (_, _) => find(_FindStatus.found, devices: _kPreviewDevices.sublist(0, 1)),
    ),
    SetupPreviewPage('1 · Find device', 'Found several', (_, _) => find(_FindStatus.found, devices: _kPreviewDevices)),
    enterCode,
    pairing,
    SetupPreviewPage('2 · Pair', 'Wrong code', (_, _) => const _PreviewPair(code: 'A7K2Q8', wrongCode: true)),
    SetupPreviewPage('3 · Wi-Fi', 'Paired', (_, _) => const _PreviewPair(paired: true)),
    SetupPreviewPage('3 · Wi-Fi', 'Looking for Wi-Fi', (_, _) => wifi(_WifiPhase.scanning)),
    SetupPreviewPage('3 · Wi-Fi', 'Network list', (_, _) => wifi(_WifiPhase.list)),
    SetupPreviewPage(
      '3 · Wi-Fi',
      'Network list with error',
      (_, _) => wifi(_WifiPhase.list, error: 'Could not scan for Wi-Fi networks.'),
    ),
    SetupPreviewPage(
      '3 · Wi-Fi',
      'Password sheet',
      (_, _) => _PreviewSheet(
        open: (context) => _WifiPasswordSheet.show(context, ssid: 'HomeNet'),
        child: wifi(_WifiPhase.list),
      ),
    ),
    SetupPreviewPage(
      '3 · Wi-Fi',
      'Hidden network sheet',
      (_, _) => _PreviewSheet(open: _HiddenNetworkSheet.show, child: wifi(_WifiPhase.list)),
    ),
    SetupPreviewPage('3 · Wi-Fi', 'No networks', (_, _) => wifi(_WifiPhase.list, networks: const [])),
    connecting,
    waiting,
    SetupPreviewPage('5 · Online', "Can't reach server", (_, _) => wifi(_WifiPhase.syncTimeout)),
    monitorOnline,
    SetupPreviewPage('6 · Device ID', 'Name your home', (_, _) => const NameHomeScreen(preview: true)),
    linkMonitor,
    SetupPreviewPage(
      'Skip path',
      'Link: checking',
      (_, _) => const _LinkDeviceScreen(preview: DeviceIdPreview.checking),
    ),
    SetupPreviewPage(
      'Skip path',
      'Link: not found',
      (_, _) => const _LinkDeviceScreen(preview: DeviceIdPreview.notFound),
    ),
    SetupPreviewPage('Skip path', 'Link: found it', (_, _) => const _LinkDeviceScreen(preview: DeviceIdPreview.found)),
    SetupPreviewPage('Skip path', "You're all set", (_, _) => const _SetupDoneScreen(preview: true)),
    SetupPreviewPage(
      'Change Wi-Fi',
      'Restarting',
      (_, _) => const _RestartMonitorScreen(deviceId: 'K7QM-4XPD', preview: _RestartPhase.waiting),
    ),
    SetupPreviewPage(
      'Change Wi-Fi',
      "Couldn't restart",
      (_, _) => const _RestartMonitorScreen(
        deviceId: 'K7QM-4XPD',
        preview: _RestartPhase.failed,
        previewError: "Your monitor was offline, so the reset didn't reach it.",
      ),
    ),
  ];

  // Screens that should get a monitor animation, highest value first
  // within flow order. Same pages as above, with what to animate.
  final animation = [
    searching.needsAnimation('Monitor sending Bluetooth waves, phone picking them up'),
    notFound.needsAnimation('Hold BOOT for 3s loop — or drop the tip if remote reset replaced BOOT'),
    enterCode.needsAnimation('Pulse a highlight where the code shows on the monitor screen'),
    pairing.needsAnimation('Phone and monitor link locking together'),
    connecting.needsAnimation('Monitor → router, a pulse travelling the link'),
    waiting.needsAnimation('Router → cloud, then the monitor lights up'),
    monitorOnline.needsAnimation('Small "monitor live" moment, in the SetupCelebration style'),
    linkMonitor.needsAnimation('Pulse a highlight where the Device ID shows on the monitor screen'),
  ];

  return (flow: flow, animation: animation);
}

/// [_PairView] with its own code field, so the preview can type into it.
class _PreviewPair extends StatefulWidget {
  final String code;
  final bool loading;
  final bool wrongCode;
  final bool paired;
  const _PreviewPair({this.code = '', this.loading = false, this.wrongCode = false, this.paired = false});

  @override
  State<_PreviewPair> createState() => _PreviewPairState();
}

class _PreviewPairState extends State<_PreviewPair> {
  late final _controller = TextEditingController(text: widget.code);
  bool _obscure = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _PairView(
      deviceName: _kPreviewDeviceName,
      controller: _controller,
      obscure: _obscure,
      onToggleObscure: () => setState(() => _obscure = !_obscure),
      onChanged: (_) => setState(() {}),
      onSkip: _noop,
      loading: widget.loading,
      wrongCode: widget.wrongCode,
      paired: widget.paired,
    );
  }
}

/// [child] with one of the setup sheets opened over it after the first frame.
class _PreviewSheet extends StatefulWidget {
  final Future<Object?> Function(BuildContext context) open;
  final Widget child;
  const _PreviewSheet({required this.open, required this.child});

  @override
  State<_PreviewSheet> createState() => _PreviewSheetState();
}

class _PreviewSheetState extends State<_PreviewSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.open(context);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
