import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max, min;
import 'dart:ui' as ui;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/ua_type.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/common/sponsor_block/skip_type.dart';
import 'package:PiliPlus/models/common/super_resolution_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/user/danmaku_rule.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_shot/data.dart';
import 'package:PiliPlus/pages/danmaku/dnamaku_model.dart';
import 'package:PiliPlus/pages/mine/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/bottom_progress_behavior.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/double_tap_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/duration.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/extension.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart' show PageUtils;
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:crclib/catalog.dart';
import 'package:dio/dio.dart' show Options;
import 'package:easy_debounce/easy_throttle.dart';
import 'package:floating/floating.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

class PlPlayerController {
  Player? _videoPlayerController;
  VideoController? _videoController;

  static PlPlayerController? _instance;

  StreamSubscription? _playerEventSubs;

  final playerStatus = PlPlayerStatus(PlayerStatus.playing);

  final PlPlayerDataStatus dataStatus = PlPlayerDataStatus();

  final Rx<Duration> _position = Rx(Duration.zero);
  final RxInt positionSeconds = 0.obs;
  final Rx<Duration> _sliderPosition = Rx(Duration.zero);
  final RxInt sliderPositionSeconds = 0.obs;
  final Rx<Duration> _sliderTempPosition = Rx(Duration.zero);
  final Rx<Duration> _duration = Rx(Duration.zero);
  final Rx<Duration> durationSeconds = Duration.zero.obs;
  final Rx<Duration> _buffered = Rx(Duration.zero);
  final RxInt bufferedSeconds = 0.obs;

  int _playerCount = 0;

  late double lastPlaybackSpeed = 1.0;
  final RxDouble _playbackSpeed = Pref.playSpeedDefault.obs;
  late final RxDouble _longPressSpeed = Pref.longPressSpeedDefault.obs;
  final RxDouble _currentVolume = RxDouble(
    Utils.isDesktop ? Pref.desktopVolume : 1.0,
  );
  final RxDouble _currentBrightness = (-1.0).obs;

  final RxBool _showControls = false.obs;
  final RxBool _showVolumeStatus = false.obs;
  final RxBool _showBrightnessStatus = false.obs;
  final RxBool _longPressStatus = false.obs;
  final RxBool _controlsLock = false.obs;
  final RxBool _isFullScreen = false.obs;
  bool isLive = false;

  bool _isVertical = false;

  final Rx<VideoFitType> _videoFit = Rx(VideoFitType.contain);
  late StreamSubscription<DataStatus> _dataListenerForVideoFit;
  late StreamSubscription<DataStatus> _dataListenerForEnterFullscreen;

  // 两步全屏：先竖屏沉浸式全屏，再旋转到横屏
  bool _portraitFsFirstStep = false;
  VideoFitType? _fitBeforePortraitFs;

  bool get _deviceIsPortrait {
    final size = Get.mediaQuery.size;
    return size.height >= size.width;
  }

  Future<void> _enterPortraitFullscreenStep() async {
    hideStatusBar();
    _portraitFsFirstStep = true;
    _fitBeforePortraitFs ??= _videoFit.value;
    if (_videoFit.value != VideoFitType.contain) {
      _videoFit.value = VideoFitType.contain;
    }
    if (!_isFullScreen.value) {
      _isFullScreen.value = true;
      updateSubtitleStyle();
    }
  }

  void _clearPortraitFullscreenStep() {
    if (_portraitFsFirstStep) {
      _portraitFsFirstStep = false;
      if (_fitBeforePortraitFs != null) {
        _videoFit.value = _fitBeforePortraitFs!;
        _fitBeforePortraitFs = null;
      }
    }
  }

  late final RxBool _continuePlayInBackground =
      Pref.continuePlayInBackground.obs;

  final RxBool _isSliderMoving = false.obs;
  PlaylistMode _looping = PlaylistMode.none;
  bool _autoPlay = false;

  int? _aid;
  String? _bvid;
  int? cid;
  int? _epid;
  int? _seasonId;
  int? _pgcType;
  VideoType _videoType = VideoType.ugc;
  int _heartDuration = 0;
  int? width;
  int? height;

  late final tryLook = !Accounts.get(AccountType.video).isLogin && Pref.p1080;

  late DataSource dataSource;

  Timer? _timer;
  Timer? _timerForSeek;
  Timer? _timerForShowingVolume;

  Box setting = GStorage.setting;

  String get bvid => _bvid!;

  Stream<DataStatus> get onDataStatusChanged => dataStatus.status.stream;

  Stream<PlayerStatus> get onPlayerStatusChanged => playerStatus.stream;

  Rx<Duration> get duration => _duration;
  Stream<Duration> get onDurationChanged => _duration.stream;

  Rx<Duration> get position => _position;
  Stream<Duration> get onPositionChanged => _position.stream;

  double get playbackSpeed => _playbackSpeed.value;

  double get longPressSpeed => _longPressSpeed.value;

  Rx<Duration> get buffered => _buffered;
  Stream<Duration> get onBufferedChanged => _buffered.stream;

  Player? get videoPlayerController => _videoPlayerController;

  VideoController? get videoController => _videoController;

  RxBool get isSliderMoving => _isSliderMoving;

  Rx<Duration> get sliderPosition => _sliderPosition;
  Stream<Duration> get onSliderPositionChanged => _sliderPosition.stream;

  Rx<Duration> get sliderTempPosition => _sliderTempPosition;

  RxBool get showControls => _showControls;
  Stream<bool> get onShowControlsChanged => _showControls.stream;

  RxBool get showVolumeStatus => _showVolumeStatus;
  Stream<bool> get onShowVolumeStatusChanged => _showVolumeStatus.stream;

  RxBool get showBrightnessStatus => _showBrightnessStatus;
  Stream<bool> get onShowBrightnessStatusChanged =>
      _showBrightnessStatus.stream;

  RxDouble get volume => _currentVolume;
  Stream<double> get onVolumeChanged => _currentVolume.stream;
  late bool isMuted = false;

  RxDouble get brightness => _currentBrightness;
  Stream<double> get onBrightnessChanged => _currentBrightness.stream;

  PlaylistMode get looping => _looping;

  bool get autoplay => _autoPlay;

  Rx<VideoFitType> get videoFit => _videoFit;

  RxBool get continuePlayInBackground => _continuePlayInBackground;

  late final RxBool onlyPlayAudio = false.obs;

  late final RxBool flipX = false.obs;

  late final RxBool flipY = false.obs;

  RxBool get longPressStatus => _longPressStatus;

  RxBool isBuffering = true.obs;

  RxBool get controlsLock => _controlsLock;

  RxBool get isFullScreen => _isFullScreen;

  bool get isVertical => _isVertical;

  late final RxBool _enableShowDanmaku = Pref.enableShowDanmaku.obs;
  late final RxBool _enableShowLiveDanmaku = Pref.enableShowLiveDanmaku.obs;
  RxBool get enableShowDanmaku =>
      isLive ? _enableShowLiveDanmaku : _enableShowDanmaku;

  late final bool autoPiP = Pref.autoPiP;
  bool get isPipMode =>
      (Platform.isAndroid && Floating().isPipMode) ||
      (Utils.isDesktop && isDesktopPip);
  late bool isDesktopPip = false;
  late Rect _lastWindowBounds;

  Offset initialFocalPoint = Offset.zero;

  Future<void> exitDesktopPip() async {
    isDesktopPip = false;
    await Future.wait([
      windowManager.setTitleBarStyle(TitleBarStyle.normal),
      windowManager.setMinimumSize(const Size(400, 700)),
      windowManager.setBounds(_lastWindowBounds),
      windowManager.setAlwaysOnTop(false),
      setting.putAll({
        SettingBoxKey.windowSize: [
          _lastWindowBounds.width,
          _lastWindowBounds.height,
        ],
        SettingBoxKey.windowPosition: [
          _lastWindowBounds.left,
          _lastWindowBounds.top,
        ],
      }),
    ]);
  }

  Future<void> enterDesktopPip() async {
    if (isFullScreen.value) return;

    isDesktopPip = true;

    _lastWindowBounds = await windowManager.getBounds();

    windowManager.setTitleBarStyle(TitleBarStyle.hidden);

    late final Size size;
    final state = videoController!.player.state;
    final width = state.width ?? this.width ?? 16;
    final height = state.height ?? this.height ?? 9;
    if (height > width) {
      size = Size(280.0, 280.0 * height / width);
    } else {
      size = Size(280.0 * width / height, 280.0);
    }

    await windowManager.setMinimumSize(size);
    windowManager
      ..setSize(size)
      ..setAlwaysOnTop(true);
  }

  void toggleDesktopPip() {
    if (isDesktopPip) {
      exitDesktopPip();
    } else {
      enterDesktopPip();
    }
  }

  late bool _shouldSetPip = false;

  bool get _isCurrVideoPage {
    final currentRoute = Get.currentRoute;
    return currentRoute.startsWith('/video') ||
        currentRoute.startsWith('/liveRoom');
  }

  bool get _isPreviousVideoPage {
    final previousRoute = Get.previousRoute;
    return previousRoute.startsWith('/video') ||
        previousRoute.startsWith('/liveRoom');
  }

  void enterPip({bool isAuto = false}) {
    if (videoController != null) {
      final state = videoController!.player.state;
      PageUtils.enterPip(
        isAuto: isAuto,
        width: state.width ?? width,
        height: state.height ?? height,
      );
    }
  }

  void disableAutoEnterPipIfNeeded() {
    if (!_isPreviousVideoPage) {
      disableAutoEnterPip();
    }
  }

  void disableAutoEnterPip() {
    if (_shouldSetPip) {
      Utils.channel.invokeMethod('setPipAutoEnterEnabled', {
        'autoEnable': false,
      });
    }
  }

  late final enableTapDm = Utils.isMobile && Pref.enableTapDm;
  late int danmakuWeight = Pref.danmakuWeight;
  late RuleFilter filters = Pref.danmakuFilterRule;
  DanmakuController<DanmakuExtra>? danmakuController;
  bool showDanmaku = true;
  Set<int> dmState = <int>{};
  late final mergeDanmaku = Pref.mergeDanmaku;
  late final String midHash = Crc32Xz()
      .convert(utf8.encode(Accounts.main.mid.toString()))
      .toRadixString(16);
  late Set<int> blockTypes = Pref.danmakuBlockType;
  late bool blockColorful = blockTypes.contains(6);
  late double showArea = Pref.danmakuShowArea;
  late RxDouble danmakuOpacity = Pref.danmakuOpacity.obs;
  late double danmakuFontScale = Pref.danmakuFontScale;
  late double danmakuFontScaleFS = Pref.danmakuFontScaleFS;
  late double danmakuStrokeWidth = Pref.strokeWidth;
  late int danmakuFontWeight = Pref.fontWeight;
  late bool massiveMode = Pref.danmakuMassiveMode;
  late double danmakuDuration = Pref.danmakuDuration;
  late double danmakuStaticDuration = Pref.danmakuStaticDuration;
  late List<double> speedList = Pref.speedList;
  late bool enableAutoLongPressSpeed = Pref.enableAutoLongPressSpeed;
  late final showControlDuration = Pref.enableLongShowControl
      ? const Duration(seconds: 30)
      : const Duration(seconds: 3);
  late double subtitleFontScale = Pref.subtitleFontScale;
  late double subtitleFontScaleFS = Pref.subtitleFontScaleFS;
  late double danmakuLineHeight = Pref.danmakuLineHeight;
  late int subtitlePaddingH = Pref.subtitlePaddingH;
  late int subtitlePaddingB = Pref.subtitlePaddingB;
  late double subtitleBgOpaticy = Pref.subtitleBgOpaticy;
  final bool showVipDanmaku = Pref.showVipDanmaku;
  final bool showSpecialDanmaku = Pref.showSpecialDanmaku;
  late double subtitleStrokeWidth = Pref.subtitleStrokeWidth;
  late int subtitleFontWeight = Pref.subtitleFontWeight;

  late final pgcSkipType = Pref.pgcSkipType;
  late final enablePgcSkip = Pref.pgcSkipType != SkipType.disable;
  late final bool enableSponsorBlock = Pref.enableSponsorBlock || enablePgcSkip;
  late final double blockLimit = Pref.blockLimit;
  late final blockSettings = Pref.blockSettings;
  late final List<Color> blockColor = Pref.blockColor;
  late final Set<String> enableList = blockSettings
      .where((item) => item.second != SkipType.disable)
      .map((item) => item.first.name)
      .toSet();
  late final blockServer = Pref.blockServer;

  late final showFSActionItem = Pref.showFSActionItem;
  late final enableShrinkVideoSize = Pref.enableShrinkVideoSize;
  late final darkVideoPage = Pref.darkVideoPage;
  late final enableSlideVolumeBrightness = Pref.enableSlideVolumeBrightness;
  late final enableSlideFS = Pref.enableSlideFS;
  late final enableDragSubtitle = Pref.enableDragSubtitle;
  late final fastForBackwardDuration = Duration(
    seconds: Pref.fastForBackwardDuration,
  );

  late final horizontalSeasonPanel = Pref.horizontalSeasonPanel;
  late final preInitPlayer = Pref.preInitPlayer;
  late final showRelatedVideo = Pref.showRelatedVideo;
  late final showVideoReply = Pref.showVideoReply;
  late final showBangumiReply = Pref.showBangumiReply;
  late final reverseFromFirst = Pref.reverseFromFirst;
  late final horizontalPreview = Pref.horizontalPreview;
  late final showDmChart = Pref.showDmChart;
  late final showViewPoints = Pref.showViewPoints;
  late final showFsScreenshotBtn = Pref.showFsScreenshotBtn;
  late final showFsLockBtn = Pref.showFsLockBtn;
  late final keyboardControl = Pref.keyboardControl;

  late final bool autoExitFullscreen = Pref.autoExitFullscreen;
  late final bool autoPlayEnable = Pref.autoPlayEnable;
  late final bool enableVerticalExpand = Pref.enableVerticalExpand;
  late final bool pipNoDanmaku = Pref.pipNoDanmaku;

  late final bool tempPlayerConf = Pref.tempPlayerConf;

  late int? cacheVideoQa = Utils.isMobile ? null : Pref.defaultVideoQa;
  late int cacheAudioQa = Pref.defaultAudioQa;
  bool enableHeart = true;

  late final bool enableHA = Pref.enableHA;
  late final String hwdec = Pref.hardwareDecoding;

  late final progressType =
      BtmProgressBehavior.values[Pref.btmProgressBehavior];
  late final enableQuickDouble = Pref.enableQuickDouble;
  late final fullScreenGestureReverse = Pref.fullScreenGestureReverse;

  late final isRelative = Pref.useRelativeSlide;
  late final offset = isRelative
      ? Pref.sliderDuration / 100
      : Pref.sliderDuration * 1000;

  num get sliderScale =>
      isRelative ? duration.value.inMilliseconds * offset : offset;

  late PlayRepeat playRepeat = PlayRepeat.values[Pref.playRepeat];

  TextStyle get subTitleStyle => TextStyle(
        height: 1.5,
        fontSize:
            16 * (isFullScreen.value ? subtitleFontScaleFS : subtitleFontScale),
        letterSpacing: 0.1,
        wordSpacing: 0.1,
        color: Colors.white,
        fontWeight: FontWeight.values[subtitleFontWeight],
        backgroundColor: subtitleBgOpaticy == 0
            ? null
            : Colors.black.withValues(alpha: subtitleBgOpaticy),
      );

  late final Rx<SubtitleViewConfiguration> subtitleConfig = _getSubConfig.obs;

  SubtitleViewConfiguration get _getSubConfig {
    final subTitleStyle = this.subTitleStyle;
    return SubtitleViewConfiguration(
      style: subTitleStyle,
      strokeStyle: subtitleBgOpaticy == 0
          ? subTitleStyle.copyWith(
              color: null,
              background: null,
              backgroundColor: null,
              foreground: Paint()
                ..color = Colors.black
                ..style = PaintingStyle.stroke
                ..strokeWidth = subtitleStrokeWidth,
            )
          : null,
      padding: EdgeInsets.only(
        left: subtitlePaddingH.toDouble(),
        right: subtitlePaddingH.toDouble(),
        bottom: subtitlePaddingB.toDouble(),
      ),
      textScaleFactor: 1,
    );
  }

  void updateSubtitleStyle() {
    subtitleConfig.value = _getSubConfig;
  }

  void onUpdatePadding(EdgeInsets padding) {
    subtitlePaddingB = padding.bottom.round().clamp(0, 200);
    putSubtitleSettings();
  }

  void updateSliderPositionSecond() {
    int newSecond = _sliderPosition.value.inSeconds;
    if (sliderPositionSeconds.value != newSecond) {
      sliderPositionSeconds.value = newSecond;
    }
  }

  void updatePositionSecond() {
    int newSecond = _position.value.inSeconds;
    if (positionSeconds.value != newSecond) {
      positionSeconds.value = newSecond;
    }
  }

  void updateDurationSecond() {
    if (durationSeconds.value != _duration.value) {
      durationSeconds.value = _duration.value;
    }
  }

  void updateBufferedSecond() {
    int newSecond = _buffered.value.inSeconds;
    if (bufferedSeconds.value != newSecond) {
      bufferedSeconds.value = newSecond;
    }
  }

  static PlPlayerController? get instance => _instance;

  static bool instanceExists() {
    return _instance != null;
  }

  static void setPlayCallBack(Function? playCallBack) {
    _playCallBack = playCallBack;
  }

  static Function? _playCallBack;

  static void playIfExists({bool repeat = false, bool hideControls = true}) {
    _playCallBack?.call();
  }

  static PlayerStatus? getPlayerStatusIfExists() {
    return _instance?.playerStatus.value;
  }

  static Future<void> pauseIfExists({
    bool notify = true,
    bool isInterrupt = false,
  }) async {
    if (_instance?.playerStatus.value == PlayerStatus.playing) {
      await _instance?.pause(notify: notify, isInterrupt: isInterrupt);
    }
  }

  static Future<void> seekToIfExists(
    Duration position, {
    bool isSeek = true,
  }) async {
    await _instance?.seekTo(position, isSeek: isSeek);
  }

  static double? getVolumeIfExists() {
    return _instance?.volume.value;
  }

  static Future<void> setVolumeIfExists(double volumeNew) async {
    await _instance?.setVolume(volumeNew);
  }

  Box video = GStorage.video;

  PlPlayerController._() {
    if (!Accounts.heartbeat.isLogin || Pref.historyPause) {
      enableHeart = false;
    }

    if (Platform.isAndroid && autoPiP) {
      Utils.sdkInt.then((sdkInt) {
        if (sdkInt < 31) {
          Utils.channel.setMethodCallHandler((call) async {
            if (call.method == 'onUserLeaveHint') {
              if (playerStatus.playing && _isCurrVideoPage) {
                enterPip();
              }
            }
          });
        } else {
          _shouldSetPip = true;
        }
      });
    }
  }

  static PlPlayerController getInstance({bool isLive = false}) {
    _instance ??= PlPlayerController._();
    _instance!
      ..isLive = isLive
      .._playerCount += 1;
    return _instance!;
  }

  bool _processing = false;
  bool get processing => _processing;

  Future<void> setDataSource(
    DataSource dataSource, {
    bool isLive = false,
    bool autoplay = true,
    PlaylistMode looping = PlaylistMode.none,
    Duration? seekTo,
    double speed = 1.0,
    int? width,
    int? height,
    Duration? duration,
    bool? isVertical,
    int? aid,
    String? bvid,
    int? cid,
    int? epid,
    int? seasonId,
    int? pgcType,
    VideoType? videoType,
    VoidCallback? callback,
    Volume? volume,
  }) async {
    try {
      _processing = true;
      this.isLive = isLive;
      _videoType = videoType ?? VideoType.ugc;
      this.width = width;
      this.height = height;
      this.dataSource = dataSource;
      _autoPlay = autoplay;
      _looping = looping;
      dataStatus.status.value = DataStatus.loading;
      _isVertical = isVertical ?? false;
      _aid = aid;
      _bvid = bvid;
      this.cid = cid;
      _epid = epid;
      _seasonId = seasonId;
      _pgcType = pgcType;

      if (showSeekPreview) {
        _clearPreview();
      }
      cancelLongPressTimer();
      if (_videoPlayerController != null &&
          _videoPlayerController!.state.playing) {
        await pause(notify: false);
      }

      if (_playerCount == 0) {
        return;
      }
      _videoPlayerController = await _createVideoController(
        dataSource,
        _looping,
        seekTo,
        volume,
      );
      callback?.call();
      _duration.value = duration ?? _videoPlayerController!.state.duration;
      _position.value = _buffered.value = _sliderPosition.value =
          seekTo ?? Duration.zero;
      updateDurationSecond();
      updatePositionSecond();
      updateSliderPositionSecond();
      updateBufferedSecond();
      dataStatus.status.value = DataStatus.loaded;

      startListeners();
      await _initializePlayer();
    } catch (err, stackTrace) {
      dataStatus.status.value = DataStatus.error;
      if (kDebugMode) {
        debugPrint(stackTrace.toString());
        debugPrint('plPlayer err:  $err');
      }
    } finally {
      _processing = false;
    }
  }

  Directory? shadersDirectory;
  Future<Directory?> copyShadersToExternalDirectory() async {
    if (shadersDirectory != null) {
      return shadersDirectory;
    }
    final manifestContent = await rootBundle.loadString('AssetManifest.json');
    final Map<String, dynamic> manifestMap = json.decode(manifestContent);
    final directory = await getApplicationSupportDirectory();
    shadersDirectory = Directory(path.join(directory.path, 'anime_shaders'));

    if (!shadersDirectory!.existsSync()) {
      await shadersDirectory!.create(recursive: true);
    }

    final shaderFiles = manifestMap.keys.where(
      (String key) =>
          key.startsWith('assets/shaders/') && key.endsWith('.glsl'),
    );

    for (var filePath in shaderFiles) {
      final fileName = filePath.split('/').last;
      final targetFile = File(path.join(shadersDirectory!.path, fileName));
      if (targetFile.existsSync()) {
        continue;
      }

      try {
        final data = await rootBundle.load(filePath);
        final List<int> bytes = data.buffer.asUint8List();
        await targetFile.writeAsBytes(bytes);
      } catch (e) {
        if (kDebugMode) debugPrint('$e');
      }
    }
    return shadersDirectory;
  }

  late final isAnim = _pgcType == 1 || _pgcType == 4;
  late final Rx<SuperResolutionType> superResolutionType =
      (isAnim ? Pref.superResolutionType : SuperResolutionType.disable).obs;
  Future<void> setShader([SuperResolutionType? type, NativePlayer? pp]) async {
    if (type == null) {
      type = superResolutionType.value;
    } else {
      superResolutionType.value = type;
      if (isAnim && !tempPlayerConf) {
        setting.put(SettingBoxKey.superResolutionType, type.index);
      }
    }
    pp ??= _videoPlayerController!.platform!;
    await pp.waitForPlayerInitialization;
    await pp.waitForVideoControllerInitializationIfAttached;
    switch (type) {
      case SuperResolutionType.disable:
        return pp.command(['change-list', 'glsl-shaders', 'clr', '']);
      case SuperResolutionType.efficiency:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          Utils.buildShadersAbsolutePath(
            (await copyShadersToExternalDirectory())?.path ?? '',
            Constants.mpvAnime4KShadersLite,
          ),
        ]);
      case SuperResolutionType.quality:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          Utils.buildShadersAbsolutePath(
            (await copyShadersToExternalDirectory())?.path ?? '',
            Constants.mpvAnime4KShaders,
          ),
        ]);
    }
  }

  static final loudnormRegExp = RegExp('loudnorm=([^,]+)');

  Future<Player> _createVideoController(
    DataSource dataSource,
    PlaylistMode looping,
    Duration? seekTo,
    Volume? volume,
  ) async {
    removeListeners();
    isBuffering.value = false;
    buffered.value = Duration.zero;
    _heartDuration = 0;
    _position.value = Duration.zero;
    danmakuController?.clear();

    Player player =
        _videoPlayerController ??
            Player(
              configuration: PlayerConfiguration(
                bufferSize: Pref.expandBuffer
                    ? (isLive ? 64 * 1024 * 1024 : 32 * 1024 * 1024)
                    : (isLive ? 16 * 1024 * 1024 : 4 * 1024 * 1024),
              ),
            );
    final pp = player.platform!;
    if (_videoPlayerController == null) {
      if (Utils.isDesktop) {
        pp.setVolume(this.volume.value * 100);
      }
      if (isAnim) {
        setShader(superResolutionType.value, pp);
      }
      await pp.setProperty(
        "af",
        "scaletempo2=max-speed=8",
      );
      if (Platform.isAndroid) {
        await pp.setProperty("volume-max", "100");
        String ao =
            Pref.useOpenSLES ? "opensles,audiotrack" : "audiotrack,opensles";
        await pp.setProperty("ao", ao);
      }
      await pp.setProperty("video-sync", Pref.videoSync);
      await player.setAudioTrack(AudioTrack.auto());
    }

    if (dataSource.audioSource?.isNotEmpty == true) {
      await pp.setProperty(
        'audio-files',
        Platform.isWindows
            ? dataSource.audioSource!.replaceAll(';', '\\;')
            : dataSource.audioSource!.replaceAll(':', '\\:'),
      );
    } else {
      await pp.setProperty('audio-files', '');
    }

    if (dataSource.subFiles?.isNotEmpty == true) {
      await pp.setProperty(
        'sub-files',
        Platform.isWindows
            ? dataSource.subFiles!.replaceAll(';', '\\;')
            : dataSource.subFiles!.replaceAll(':', '\\:'),
      );
      await pp.setProperty("subs-with-matching-audio", "no");
      await pp.setProperty("sub-forced-only", "yes");
      await pp.setProperty("blend-subtitles", "video");
    }

    _videoController ??= VideoController(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: enableHA,
        androidAttachSurfaceAfterVideoParameters: false,
        hwdec: enableHA ? hwdec : null,
      ),
    );

    player.setPlaylistMode(looping);

    final Map<String, String>? filters;
    if (Platform.isAndroid) {
      String audioNormalization = '';
      audioNormalization = AudioNormalization.getParamFromConfig(
        Pref.audioNormalization,
      );
      if (volume != null && volume.isNotEmpty) {
        audioNormalization = audioNormalization.replaceFirstMapped(
          loudnormRegExp,
              (i) =>
              'loudnorm=${volume.format(
                Map.fromEntries(
                  i.group(1)!.split(':').map((item) {
                    final parts = item.split('=');
                    return MapEntry(parts[0].toLowerCase(), num.parse(parts[1]));
                  }),
                ),
              )}',
        );
      } else {
        audioNormalization = audioNormalization.replaceFirst(
          loudnormRegExp,
          AudioNormalization.getParamFromConfig(Pref.fallbackNormalization),
        );
      }
      filters = audioNormalization.isEmpty
          ? null
          : {'lavfi-complex': '"[aid1] $audioNormalization [ao]"'};
    } else {
      filters = null;
    }

    if (kDebugMode) debugPrint(filters.toString());

    if (dataSource.type == DataSourceType.asset) {
      final assetUrl = dataSource.videoSource!.startsWith("asset://")
          ? dataSource.videoSource!
          : "asset://${dataSource.videoSource!}";
      await player.open(
        Media(
          assetUrl,
          httpHeaders: dataSource.httpHeaders,
          start: seekTo,
          extras: filters,
        ),
        play: false,
      );
    } else {
      await player.open(
        Media(
          dataSource.videoSource!,
          httpHeaders: dataSource.httpHeaders,
          start: seekTo,
          extras: filters,
        ),
        play: false,
      );
    }

    return player;
  }

  Future<bool> refreshPlayer() async {
    if (_videoPlayerController == null) {
      return false;
    }
    if (dataSource.videoSource.isNullOrEmpty) {
      SmartDialog.showToast('视频源为空，请重新进入本页面');
      return false;
    }
    if (!isLive) {
      if (dataSource.audioSource.isNullOrEmpty) {
        SmartDialog.showToast('音频源为空');
      } else {
        await (_videoPlayerController!.platform!).setProperty(
          'audio-files',
          Platform.isWindows
              ? dataSource.audioSource!.replaceAll(';', '\\;')
              : dataSource.audioSource!.replaceAll(':', '\\:'),
        );
      }
    }
    await _videoPlayerController!.open(
      Media(
        dataSource.videoSource!,
        httpHeaders: dataSource.httpHeaders,
        start: _position.value,
      ),
      play: true,
    );
    return true;
  }

  Future<void> _initializePlayer() async {
    if (_instance == null) return;
    if (isLive) {
      await setPlaybackSpeed(1.0);
    } else {
      if (_videoPlayerController?.state.rate != _playbackSpeed.value) {
        await setPlaybackSpeed(_playbackSpeed.value);
      }
    }
    getVideoFit();
    if (_autoPlay) {
      playIfExists();
    }
  }

  late final bool enableAutoEnter = Pref.enableAutoEnter;
  Future<void> autoEnterFullscreen() async {
    if (enableAutoEnter) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (dataStatus.status.value != DataStatus.loaded) {
          _dataListenerForEnterFullscreen = dataStatus.status.listen((status) {
            if (status == DataStatus.loaded) {
              _dataListenerForEnterFullscreen.cancel();
              triggerFullScreen(status: true);
            }
          });
        } else {
          triggerFullScreen(status: true);
        }
      });
    }
  }

  Set<StreamSubscription> subscriptions = {};
  final Set<Function(Duration position)> _positionListeners = {};
  final Set<Function(PlayerStatus status)> _statusListeners = {};

  void startListeners() {
    subscriptions = {
      videoPlayerController!.stream.playing.listen((event) {
        if (event) {
          if (_shouldSetPip) {
            if (_isCurrVideoPage) {
              enterPip(isAuto: true);
            } else {
              disableAutoEnterPip();
            }
          }
          playerStatus.value = PlayerStatus.playing;
        } else {
          disableAutoEnterPip();
          playerStatus.value = PlayerStatus.paused;
        }
        videoPlayerServiceHandler?.onStatusChange(
          playerStatus.value,
          isBuffering.value,
          isLive,
        );

        for (var element in _statusListeners) {
          element(event ? PlayerStatus.playing : PlayerStatus.paused);
        }
        if (videoPlayerController!.state.position.inSeconds != 0) {
          makeHeartBeat(positionSeconds.value, type: HeartBeatType.status);
        }
      }),
      videoPlayerController!.stream.completed.listen((event) {
        if (event) {
          playerStatus.value = PlayerStatus.completed;

          for (var element in _statusListeners) {
            element(PlayerStatus.completed);
          }
        }
        makeHeartBeat(positionSeconds.value, type: HeartBeatType.completed);
      }),
      videoPlayerController!.stream.position.listen((event) {
        _position.value = event;
        updatePositionSecond();
        if (!isSliderMoving.value) {
          _sliderPosition.value = event;
          updateSliderPositionSecond();
        }

        for (var element in _positionListeners) {
          element(event);
        }
        makeHeartBeat(event.inSeconds);
      }),
      videoPlayerController!.stream.duration.listen((Duration event) {
        duration.value = event;
      }),
      videoPlayerController!.stream.buffer.listen((Duration event) {
        _buffered.value = event;
        updateBufferedSecond();
      }),
      videoPlayerController!.stream.buffering.listen((bool event) {
        isBuffering.value = event;
        videoPlayerServiceHandler?.onStatusChange(
          playerStatus.value,
          event,
          isLive,
        );
      }),
      if (kDebugMode)
        videoPlayerController!.stream.log.listen(((PlayerLog log) {
          debugPrint(log.toString());
        })),
      videoPlayerController!.stream.error.listen((String event) {
        debugPrint('MPV Exception: $event');
        if (isLive) {
          if (event.startsWith('tcp: ffurl_read returned ') ||
              event.startsWith("Failed to open https://") ||
              event.startsWith("Can not open external file https://")) {
            Future.delayed(const Duration(milliseconds: 3000), refreshPlayer);
          }
          return;
        }
        if (event.startsWith("Failed to open https://") ||
            event.startsWith("Can not open external file https://") ||
            event.startsWith('tcp: ffurl_read returned ')) {
          EasyThrottle.throttle(
            'videoPlayerController!.stream.error.listen',
            const Duration(milliseconds: 10000),
            () {
              Future.delayed(const Duration(milliseconds: 3000), () async {
                if (isBuffering.value && _buffered.value == Duration.zero) {
                  SmartDialog.showToast(
                    '视频链接打开失败，重试中',
                    displayTime: const Duration(milliseconds: 500),
                  );
                  if (!await refreshPlayer()) {
                    if (kDebugMode) debugPrint("failed");
                  }
                }
              });
            },
          );
        } else if (event.startsWith('Could not open codec')) {
          SmartDialog.showToast('无法加载解码器, $event，可能会切换至软解');
        } else if (!onlyPlayAudio.value) {
          if (event.startsWith("error running") ||
              event.startsWith("Failed to open .") ||
              event.startsWith("Cannot open") ||
              event.startsWith("Can not open")) {
            return;
          }
          SmartDialog.showToast('视频加载错误, $event');
        }
      }),
      if (videoPlayerServiceHandler != null) ...[
        onPlayerStatusChanged.listen((PlayerStatus event) {
          videoPlayerServiceHandler!.onStatusChange(
            event,
            isBuffering.value,
            isLive,
          );
        }),
        onPositionChanged.listen((Duration event) {
          EasyThrottle.throttle(
            'mediaServicePosition',
            const Duration(seconds: 1),
            () => videoPlayerServiceHandler!.onPositionChange(event),
          );
        }),
      ],
    };
  }

  Future<void> removeListeners() async {
    await Future.wait(subscriptions.map((e) => e.cancel()));
  }

  Future<void> seekTo(Duration position, {bool isSeek = true}) async {
    if (_playerCount == 0) {
      return;
    }
    if (position < Duration.zero) {
      position = Duration.zero;
    }
    _position.value = position;
    updatePositionSecond();
    _heartDuration = position.inSeconds;
    if (duration.value.inSeconds != 0) {
      if (isSeek) {
        await _videoPlayerController?.stream.buffer.first;
      }
      danmakuController?.clear();
      try {
        await _videoPlayerController?.seek(position);
      } catch (e) {
        if (kDebugMode) debugPrint('seek failed: $e');
      }
    } else {
      _timerForSeek?.cancel();
      _timerForSeek = Timer.periodic(const Duration(milliseconds: 200), (
        Timer t,
      ) async {
        if (_playerCount == 0) {
          _timerForSeek?.cancel();
          _timerForSeek = null;
        } else if (duration.value.inSeconds != 0) {
          try {
            await _videoPlayerController?.stream.buffer.first;
            danmakuController?.clear();
            await _videoPlayerController?.seek(position);
          } catch (e) {
            if (kDebugMode) debugPrint('seek failed: $e');
          }
          t.cancel();
          _timerForSeek = null;
        }
      });
    }
  }

  Future<void> setPlaybackSpeed(double speed) async {
    lastPlaybackSpeed = playbackSpeed;

    if (speed == _videoPlayerController?.state.rate) {
      return;
    }

    await _videoPlayerController?.setRate(speed);
    _playbackSpeed.value = speed;
    if (danmakuController != null) {
      try {
        DanmakuOption currentOption = danmakuController!.option;
        double defaultDuration = currentOption.duration * lastPlaybackSpeed;
        double defaultStaticDuration =
            currentOption.staticDuration * lastPlaybackSpeed;
        DanmakuOption updatedOption = currentOption.copyWith(
          duration: defaultDuration / speed,
          staticDuration: defaultStaticDuration / speed,
        );
        danmakuController!.updateOption(updatedOption);
      } catch (_) {}
    }
  }

  double playSpeedDefault = Pref.playSpeedDefault;
  Future<void> setDefaultSpeed() async {
    await _videoPlayerController?.setRate(playSpeedDefault);
    _playbackSpeed.value = playSpeedDefault;
  }

  Future<void> play({bool repeat = false, bool hideControls = true}) async {
    if (_playerCount == 0) return;
    controls = !hideControls;
    if (repeat) {
      await seekTo(Duration.zero, isSeek: false);
    }

    await _videoPlayerController?.play();

    audioSessionHandler?.setActive(true);

    playerStatus.value = PlayerStatus.playing;
  }

  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    await _videoPlayerController?.pause();
    playerStatus.value = PlayerStatus.paused;

    if (!isInterrupt) {
      audioSessionHandler?.setActive(false);
    }
  }

  bool tripling = false;

  void hideTaskControls() {
    _timer?.cancel();
    _timer = Timer(showControlDuration, () {
      if (!isSliderMoving.value && !tripling) {
        controls = false;
      }
      _timer = null;
    });
  }

  void onChangedSlider(double v) {
    _sliderPosition.value = Duration(seconds: v.floor());
    updateSliderPositionSecond();
  }

  void onChangedSliderStart([Duration? value]) {
    if (value != null) {
      _sliderTempPosition.value = value;
    }
    _isSliderMoving.value = true;
  }

  bool? cancelSeek;
  bool? hasToast;

  void onUpdatedSliderProgress(Duration value) {
    _sliderTempPosition.value = value;
    _sliderPosition.value = value;
    updateSliderPositionSecond();
  }

  void onChangedSliderEnd() {
    if (cancelSeek != true) {
      feedBack();
    }
    cancelSeek = null;
    hasToast = null;
    _isSliderMoving.value = false;
    hideTaskControls();
  }

  final RxBool volumeIndicator = false.obs;
  Timer? volumeTimer;
  final RxBool volumeInterceptEventStream = false.obs;

  Future<void> setVolume(double volume) async {
    if (this.volume.value != volume) {
      this.volume.value = volume;
      try {
        if (Utils.isDesktop) {
          _videoPlayerController!.setVolume(volume * 100);
        } else {
          FlutterVolumeController.updateShowSystemUI(false);
          await FlutterVolumeController.setVolume(volume);
        }
      } catch (err) {
        if (kDebugMode) debugPrint(err.toString());
      }
    }
    volumeIndicator.value = true;
    volumeInterceptEventStream.value = true;
    volumeTimer?.cancel();
    volumeTimer = Timer(const Duration(milliseconds: 200), () {
      volumeIndicator.value = false;
      volumeInterceptEventStream.value = false;
      if (Utils.isDesktop) {
        setting.put(SettingBoxKey.desktopVolume, volume.toPrecision(3));
      }
    });
  }

  void volumeUpdated() {
    showVolumeStatus.value = true;
    _timerForShowingVolume?.cancel();
    _timerForShowingVolume = Timer(const Duration(seconds: 1), () {
      showVolumeStatus.value = false;
    });
  }

  void setCurrBrightness(double brightness) {
    _currentBrightness.value = brightness;
  }

  void toggleVideoFit(VideoFitType value) {
    _videoFit.value = value;
    video.put(VideoBoxKey.cacheVideoFit, _videoFit.value.index);
  }

  int fitValue = Pref.cacheVideoFit;
  Future<void> getVideoFit() async {
    var attr = VideoFitType.values[fitValue];
    if (attr == VideoFitType.none || attr == VideoFitType.scaleDown) {
      if (buffered.value == Duration.zero) {
        attr = VideoFitType.contain;
        _dataListenerForVideoFit = dataStatus.status.listen((status) {
          if (status == DataStatus.loaded) {
            _dataListenerForVideoFit.cancel();
            var attr = VideoFitType.values[fitValue];
            if (attr == VideoFitType.none || attr == VideoFitType.scaleDown) {
              _videoFit.value = attr;
            }
          }
        });
      }
    } else if (attr == VideoFitType.fill && isVertical) {
      attr = VideoFitType.contain;
    }
    _videoFit.value = attr;
  }

  Future<void> setBackgroundPlay(bool val) async {
    videoPlayerServiceHandler?.enableBackgroundPlay = val;
    if (!tempPlayerConf) {
      setting.put(SettingBoxKey.enableBackgroundPlay, val);
    }
  }

  set controls(bool visible) {
    _showControls.value = visible;
    _timer?.cancel();
    if (visible) {
      hideTaskControls();
    }
  }

  void hiddenControls(bool val) {
    showControls.value = val;
  }

  Timer? longPressTimer;
  void cancelLongPressTimer() {
    longPressTimer?.cancel();
    longPressTimer = null;
  }

  Future<void> setLongPressStatus(bool val) async {
    if (isLive) {
      return;
    }
    if (controlsLock.value) {
      return;
    }
    if (_longPressStatus.value == val) {
      return;
    }
    if (val) {
      if (playerStatus.value == PlayerStatus.playing) {
        _longPressStatus.value = val;
        HapticFeedback.lightImpact();
        await setPlaybackSpeed(
          enableAutoLongPressSpeed ? playbackSpeed * 2 : longPressSpeed,
        );
      }
    } else {
      _longPressStatus.value = val;
      await setPlaybackSpeed(lastPlaybackSpeed);
    }
  }

  bool get _isCompleted =>
      videoPlayerController!.state.completed ||
      (duration.value - position.value).inMilliseconds <= 50;

  Future<void> onDoubleTapCenter() async {
    if (!isLive && _isCompleted) {
      await videoPlayerController!.seek(Duration.zero);
      videoPlayerController!.play();
    } else {
      videoPlayerController!.playOrPause();
    }
  }

  final RxBool mountSeekBackwardButton = false.obs;
  final RxBool mountSeekForwardButton = false.obs;

  void onDoubleTapSeekBackward() {
    mountSeekBackwardButton.value = true;
  }

  void onDoubleTapSeekForward() {
    mountSeekForwardButton.value = true;
  }

  void onForward(Duration duration) {
    onForwardBackward(_position.value + duration);
  }

  void onBackward(Duration duration) {
    onForwardBackward(_position.value - duration);
  }

  void onForwardBackward(Duration duration) {
    seekTo(
      duration.clamp(Duration.zero, videoPlayerController!.state.duration),
      isSeek: false,
    ).whenComplete(play);
  }

  void doubleTapFuc(DoubleTapType type) {
    if (!enableQuickDouble) {
      onDoubleTapCenter();
      return;
    }
    switch (type) {
      case DoubleTapType.left:
        onDoubleTapSeekBackward();
        break;
      case DoubleTapType.center:
        onDoubleTapCenter();
        break;
      case DoubleTapType.right:
        onDoubleTapSeekForward();
        break;
    }
  }

  void onLockControl(bool val) {
    feedBack();
    _controlsLock.value = val;
    if (!val && _showControls.value) {
      _showControls.refresh();
    }
    controls = !val;
  }

  void toggleFullScreen(bool val) {
    _isFullScreen.value = val;
    updateSubtitleStyle();
  }

  late bool isManualFS = true;
  late final FullScreenMode mode = FullScreenMode.values[Pref.fullScreenMode];
  late final horizontalScreen = Pref.horizontalScreen;

  bool fsProcessing = false;
  Future<void> triggerFullScreen({
    bool status = true,
    bool inAppFullScreen = false,
    bool isManualFS = true,
    FullScreenMode? mode,
  }) async {
    if (isDesktopPip) return;

    // 二次点击（无论 status true/false）都从“竖屏全屏第一步”切到横屏
    if (_portraitFsFirstStep && Utils.isMobile) {
      await landscape();
      _clearPortraitFullscreenStep();
      _isFullScreen.value = true;
      updateSubtitleStyle();
      return;
    }

    if (isFullScreen.value == status) return;

    if (fsProcessing) {
      return;
    }
    fsProcessing = true;

    mode ??= this.mode;
    this.isManualFS = isManualFS;
    toggleFullScreen(status);

    if (status) {
      if (Utils.isMobile) {
        hideStatusBar();

        if (_deviceIsPortrait && !isVertical) {
          await _enterPortraitFullscreenStep();
          fsProcessing = false;
          return;
        }

        if (mode == FullScreenMode.none) {
          fsProcessing = false;
          return;
        }
        if (mode == FullScreenMode.gravity) {
          await fullAutoModeForceSensor();
          fsProcessing = false;
          return;
        }
        late final size = Get.mediaQuery.size;
        if ((mode == FullScreenMode.vertical ||
            (mode == FullScreenMode.auto && isVertical) ||
            (mode == FullScreenMode.ratio &&
                (isVertical || size.height / size.width < kScreenRatio)))) {
          await verticalScreenForTwoSeconds();
        } else {
          await landscape();
        }
      } else {
        await enterDesktopFullscreen(inAppFullScreen: inAppFullScreen);
      }
    } else {
      if (Utils.isMobile) {
        showStatusBar();
        _clearPortraitFullscreenStep();
        if (mode == FullScreenMode.none) {
          fsProcessing = false;
          return;
        }
        if (!horizontalScreen) {
          await verticalScreenForTwoSeconds();
        } else {
          await autoScreen();
        }
      } else {
        await exitDesktopFullscreen();
      }
    }
    fsProcessing = false;
  }

  void addPositionListener(Function(Duration position) listener) =>
      _positionListeners.add(listener);
  void removePositionListener(Function(Duration position) listener) =>
      _positionListeners.remove(listener);
  void addStatusLister(Function(PlayerStatus status) listener) =>
      _statusListeners.add(listener);
  void removeStatusLister(Function(PlayerStatus status) listener) =>
      _statusListeners.remove(listener);

  Future<Uint8List?> screenshot() async {
    final Uint8List? screenshot = await _videoPlayerController!.screenshot(
      format: 'image/png',
    );
    return screenshot;
  }

  Future<void> makeHeartBeat(
    int progress, {
    HeartBeatType type = HeartBeatType.playing,
    bool isManual = false,
    dynamic aid,
    dynamic bvid,
    dynamic cid,
    dynamic epid,
    dynamic seasonId,
    dynamic pgcType,
    VideoType? videoType,
  }) async {
    if (isLive) {
      return;
    }
    if (!enableHeart || MineController.anonymity.value || progress == 0) {
      return;
    } else if (playerStatus.value == PlayerStatus.paused) {
      if (!isManual) {
        return;
      }
    }
    bool isComplete =
        playerStatus.value == PlayerStatus.completed ||
        type == HeartBeatType.completed;
    if ((durationSeconds.value - position.value).inMilliseconds > 1000) {
      isComplete = false;
    }

    if (type == HeartBeatType.status || type == HeartBeatType.completed) {
      await VideoHttp.heartBeat(
        aid: aid ?? _aid,
        bvid: bvid ?? _bvid,
        cid: cid ?? this.cid,
        progress: isComplete ? -1 : progress,
        epid: epid ?? _epid,
        seasonId: seasonId ?? _seasonId,
        subType: pgcType ?? _pgcType,
        videoType: videoType ?? _videoType,
      );
      return;
    } else if (progress - _heartDuration >= 5) {
      _heartDuration = progress;
      await VideoHttp.heartBeat(
        aid: aid ?? _aid,
        bvid: bvid ?? _bvid,
        cid: cid ?? this.cid,
        progress: progress,
        epid: epid ?? _epid,
        seasonId: seasonId ?? _seasonId,
        subType: pgcType ?? _pgcType,
        videoType: videoType ?? _videoType,
      );
    }
  }

  void setPlayRepeat(PlayRepeat type) {
    playRepeat = type;
    video.put(VideoBoxKey.playRepeat, type.index);
  }

  void putDanmakuSettings() {
    setting.putAll({
      SettingBoxKey.danmakuWeight: danmakuWeight,
      SettingBoxKey.danmakuBlockType: blockTypes.toList(),
      SettingBoxKey.danmakuShowArea: showArea,
      SettingBoxKey.danmakuOpacity: danmakuOpacity.value,
      SettingBoxKey.danmakuFontScale: danmakuFontScale,
      SettingBoxKey.danmakuFontScaleFS: danmakuFontScaleFS,
      SettingBoxKey.danmakuDuration: danmakuDuration,
      SettingBoxKey.danmakuStaticDuration: danmakuStaticDuration,
      SettingBoxKey.strokeWidth: danmakuStrokeWidth,
      SettingBoxKey.fontWeight: danmakuFontWeight,
      SettingBoxKey.danmakuLineHeight: danmakuLineHeight,
    });
  }

  void putSubtitleSettings() {
    setting.putAll({
      SettingBoxKey.subtitleFontScale: subtitleFontScale,
      SettingBoxKey.subtitleFontScaleFS: subtitleFontScaleFS,
      SettingBoxKey.subtitlePaddingH: subtitlePaddingH,
      SettingBoxKey.subtitlePaddingB: subtitlePaddingB,
      SettingBoxKey.subtitleBgOpaticy: subtitleBgOpaticy,
      SettingBoxKey.subtitleStrokeWidth: subtitleStrokeWidth,
      SettingBoxKey.subtitleFontWeight: subtitleFontWeight,
    });
  }

  bool isCloseAll = false;
  Future<void> dispose() async {
    cancelLongPressTimer();
    if (!isCloseAll && _playerCount > 1) {
      _playerCount -= 1;
      _heartDuration = 0;
      if (!_isPreviousVideoPage) {
        pause();
      }
      return;
    }
    _playerCount = 0;
    disableAutoEnterPip();
    setPlayCallBack(null);
    dmState.clear();
    _clearPreview();
    Utils.channel.setMethodCallHandler(null);
    _timer?.cancel();
    _timerForSeek?.cancel();
    _timerForShowingVolume?.cancel();
    _playerEventSubs?.cancel();

    await removeListeners();
    _videoPlayerController?.dispose();
    _videoPlayerController = null;
    _videoController = null;
    _instance = null;
    videoPlayerServiceHandler?.clear();
  }

  static void updatePlayCount() {
    if (_instance?._playerCount == 1) {
      _instance?.dispose();
    } else {
      _instance?._playerCount -= 1;
    }
  }

  void setContinuePlayInBackground() {
    _continuePlayInBackground.value = !_continuePlayInBackground.value;
    if (!tempPlayerConf) {
      setting.put(
        SettingBoxKey.continuePlayInBackground,
        _continuePlayInBackground.value,
      );
    }
  }

  void setOnlyPlayAudio() {
    onlyPlayAudio.value = !onlyPlayAudio.value;
    videoPlayerController?.setVideoTrack(
      onlyPlayAudio.value ? VideoTrack.no() : VideoTrack.auto(),
    );
  }

  Map<String, WeakReference<ui.Image>>? previewCache;
  LoadingState<VideoShotData>? videoShot;
  late final RxBool showPreview = false.obs;
  late final showSeekPreview = Pref.showSeekPreview;
  late final Rx<int?> previewIndex = Rx<int?>(null);

  void updatePreviewIndex(int seconds) {
    if (videoShot == null) {
      videoShot = LoadingState.loading();
      getVideoShot();
      return;
    }
    if (videoShot case Success<VideoShotData> success) {
      final data = success.response;
      if (!showPreview.value) {
        showPreview.value = true;
      }
      previewIndex.value = max(
        0,
        (data.index.where((item) => item <= seconds).length - 2),
      );
    }
  }

  void _clearPreview() {
    showPreview.value = false;
    previewIndex.value = null;
    videoShot = null;
    previewCache
      ?..forEach((_, ref) {
        try {
          ref.target?.dispose();
        } catch (_) {}
      })
      ..clear();
    previewCache = null;
  }

  Future<void> getVideoShot() async {
    try {
      var res = await Request().get(
        '/x/player/videoshot',
        queryParameters: {
          'bvid': _bvid,
          'cid': cid,
          'index': 1,
        },
        options: Options(
          headers: {
            'user-agent': UaType.pc.ua,
            'referer': 'https://www.bilibili.com/video/$bvid',
          },
        ),
      );
      if (res.data['code'] == 0) {
        final data = VideoShotData.fromJson(res.data['data']);
        if (data.index.isNotEmpty) {
          videoShot = Success(data);
          return;
        }
      }
      videoShot = const Error(null);
    } catch (e) {
      videoShot = const Error(null);
      if (kDebugMode) debugPrint('getVideoShot: $e');
    }
  }

  void takeScreenshot() {
    SmartDialog.showToast('截图中');
    videoPlayerController?.screenshot(format: 'image/png').then((value) {
      if (value != null) {
        SmartDialog.showToast('点击弹窗保存截图');
        Get.dialog(
          GestureDetector(
            onTap: () {
              Get.back();
              ImageUtils.saveByteImg(
                bytes: value,
                fileName: 'screenshot_${ImageUtils.time}',
              );
            },
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: min(Get.width / 3, 350),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        width: 5,
                        color: Get.theme.colorScheme.surface,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: Image.memory(value),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      } else {
        SmartDialog.showToast('截图失败');
      }
    });
  }
}