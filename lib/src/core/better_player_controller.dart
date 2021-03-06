import 'dart:async';
import 'dart:io';

import 'package:better_player/better_player.dart';
import 'package:better_player/src/configuration/better_player_configuration.dart';
import 'package:better_player/src/configuration/better_player_event.dart';
import 'package:better_player/src/configuration/better_player_event_type.dart';
import 'package:better_player/src/core/better_player_controller_provider.dart';
import 'package:better_player/src/subtitles/better_player_subtitle.dart';
import 'package:better_player/src/subtitles/better_player_subtitles_factory.dart';
import 'package:better_player/src/video_player/video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class BetterPlayerController extends ChangeNotifier {
  static const _durationParameter = "duration";
  static const _progressParameter = "progress";
  static const _volumeParameter = "volume";

  final BetterPlayerConfiguration betterPlayerConfiguration;
  final BetterPlayerPlaylistConfiguration betterPlayerPlaylistConfiguration;
  final BetterPlayerDataSource betterPlayerDataSource;

  VideoPlayerController videoPlayerController;

  bool get autoPlay => betterPlayerConfiguration.autoPlay;

  Duration get startAt => betterPlayerConfiguration.startAt;

  bool get looping => betterPlayerConfiguration.looping;

  Widget Function(BuildContext context, String errorMessage) get errorBuilder =>
      null;

  double get aspectRatio => betterPlayerConfiguration.aspectRatio;

  Widget get placeholder => betterPlayerConfiguration.placeholder;

  Widget get overlay => betterPlayerConfiguration.overlay;

  bool get fullScreenByDefault => betterPlayerConfiguration.fullScreenByDefault;

  bool get allowedScreenSleep => betterPlayerConfiguration.allowedScreenSleep;

  List<SystemUiOverlay> get systemOverlaysAfterFullScreen =>
      betterPlayerConfiguration.systemOverlaysAfterFullScreen;

  List<DeviceOrientation> get deviceOrientationsAfterFullScreen =>
      betterPlayerConfiguration.deviceOrientationsAfterFullScreen;

  BetterPlayerRoutePageBuilder routePageBuilder;

  /// Defines a event listener where video player events will be send
  Function(BetterPlayerEvent) get eventListener =>
      betterPlayerConfiguration.eventListener;

  bool _isFullScreen = false;

  bool get isFullScreen => _isFullScreen;

  int _lastPositionSelection = 0;

  final List<Function> _eventListeners = List();

  BetterPlayerDataSource _betterPlayerDataSource;

  List<BetterPlayerSubtitle> subtitles = List();

  Timer _nextVideoTimer;

  int _nextVideoTime;
  StreamController<int> nextVideoTimeStreamController =
      StreamController.broadcast();

  BetterPlayerController(this.betterPlayerConfiguration,
      {this.betterPlayerPlaylistConfiguration,
      this.betterPlayerDataSource,
      this.videoPlayerController})
      : assert(betterPlayerConfiguration != null,
            "BetterPlayerConfiguration can't be null") {
    _eventListeners.add(eventListener);
    if (betterPlayerDataSource != null) {
      _setup(betterPlayerDataSource);
    } else if (this.videoPlayerController != null) {
      _initialize();
    }
  }

  static BetterPlayerController of(BuildContext context) {
    final betterPLayerControllerProvider = context
        .dependOnInheritedWidgetOfExactType<BetterPlayerControllerProvider>();

    return betterPLayerControllerProvider.controller;
  }

  Future _setup(BetterPlayerDataSource dataSource) async {
    _betterPlayerDataSource = dataSource;
    if (dataSource.subtitles != null) {
      subtitles.clear();
      BetterPlayerSubtitlesFactory.parseSubtitles(dataSource.subtitles)
          .then((data) {
        subtitles.addAll(data);
      });
    }
    videoPlayerController = VideoPlayerController();

    setupDataSource(betterPlayerDataSource);
  }

  void setupDataSource(BetterPlayerDataSource betterPlayerDataSource) async {
    switch (betterPlayerDataSource.type) {
      case BetterPlayerDataSourceType.NETWORK:
        videoPlayerController.setNetworkDataSource(
          betterPlayerDataSource.url,
          headers: betterPlayerDataSource.headers,
        );

        break;
      case BetterPlayerDataSourceType.FILE:
        videoPlayerController
            .setFileDataSource(File(betterPlayerDataSource.url));
        break;
      default:
        throw UnimplementedError(
            "${betterPlayerDataSource.type} is not implemented");
    }
    await _initialize();
  }

  Future _initialize() async {
    await videoPlayerController.setLooping(looping);

    if (autoPlay) {
      if (fullScreenByDefault) {
        enterFullScreen();
      }

      await play();
    }

    if (startAt != null) {
      await videoPlayerController.seekTo(startAt);
    }

    if (fullScreenByDefault) {
      videoPlayerController.addListener(_fullScreenListener);
    }

    ///General purpose listener
    videoPlayerController.addListener(_onVideoPlayerChanged);
  }

  void _fullScreenListener() async {
    if (videoPlayerController.value.isPlaying && !_isFullScreen) {
      enterFullScreen();
      videoPlayerController.removeListener(_fullScreenListener);
    }
  }

  void enterFullScreen() {
    _isFullScreen = true;
    notifyListeners();
  }

  void exitFullScreen() {
    _isFullScreen = false;
    notifyListeners();
  }

  void toggleFullScreen() {
    _isFullScreen = !_isFullScreen;
    _postEvent(_isFullScreen
        ? BetterPlayerEvent(BetterPlayerEventType.OPEN_FULLSCREEN)
        : BetterPlayerEvent(BetterPlayerEventType.HIDE_FULLSCREEN));
    notifyListeners();
  }

  Future<void> play() async {
    await videoPlayerController.play();
    _postEvent(BetterPlayerEvent(BetterPlayerEventType.PLAY));
  }

  Future<void> setLooping(bool looping) async {
    await videoPlayerController.setLooping(looping);
  }

  Future<void> pause() async {
    await videoPlayerController.pause();
    _postEvent(BetterPlayerEvent(BetterPlayerEventType.PAUSE));
  }

  Future<void> seekTo(Duration moment) async {
    await videoPlayerController.seekTo(moment);
    _postEvent(BetterPlayerEvent(BetterPlayerEventType.SEEK_TO,
        parameters: {_durationParameter: moment}));
    if (moment > videoPlayerController.value.duration) {
      _postEvent(BetterPlayerEvent(BetterPlayerEventType.FINISHED));
    } else {
      cancelNextVideoTimer();
    }
  }

  Future<void> setVolume(double volume) async {
    await videoPlayerController.setVolume(volume);
    _postEvent(BetterPlayerEvent(BetterPlayerEventType.SET_VOLUME,
        parameters: {_volumeParameter: volume}));
  }

  Future<bool> isPlaying() async {
    return videoPlayerController.value.isPlaying;
  }

  bool isBuffering() {
    return videoPlayerController.value.isBuffering;
  }

  void toggleControlsVisibility(bool isVisible) {
    _postEvent(isVisible
        ? BetterPlayerEvent(BetterPlayerEventType.CONTROLS_VISIBLE)
        : BetterPlayerEvent(BetterPlayerEventType.CONTROLS_HIDDEN));
  }

  void _postEvent(BetterPlayerEvent betterPlayerEvent) {
    for (Function eventListener in _eventListeners) {
      if (eventListener != null) {
        eventListener(betterPlayerEvent);
      }
    }
  }

  void _onVideoPlayerChanged() async {
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPositionSelection > 500) {
      _lastPositionSelection = now;
      var currentVideoPlayerValue = videoPlayerController.value;
      Duration currentPositionShifted = Duration(
          milliseconds: currentVideoPlayerValue.position.inMilliseconds + 500);
      if (currentPositionShifted == null ||
          currentVideoPlayerValue.duration == null) {
        return;
      }

      if (currentPositionShifted > currentVideoPlayerValue.duration) {
        _postEvent(
            BetterPlayerEvent(BetterPlayerEventType.FINISHED, parameters: {
          _progressParameter: currentVideoPlayerValue.position,
          _durationParameter: currentVideoPlayerValue.duration
        }));
      } else {
        _postEvent(
            BetterPlayerEvent(BetterPlayerEventType.PROGRESS, parameters: {
          _progressParameter: currentVideoPlayerValue.position,
          _durationParameter: currentVideoPlayerValue.duration
        }));
      }
    }
  }

  void addEventsListener(Function(BetterPlayerEvent) eventListener) {
    _eventListeners.add(eventListener);
  }

  bool isLiveStream() {
    return _betterPlayerDataSource?.liveStream;
  }

  bool isVideoInitialized() {
    return videoPlayerController.value.initialized;
  }

  void startNextVideoTimer() {
    if (_nextVideoTimer == null) {
      _nextVideoTime =
          betterPlayerPlaylistConfiguration.nextVideoDelay.inSeconds;
      nextVideoTimeStreamController.add(_nextVideoTime);
      _nextVideoTimer =
          Timer.periodic(Duration(milliseconds: 1000), (_timer) async {
        if (_nextVideoTime == 1) {
          _timer.cancel();
        }
        _nextVideoTime -= 1;
        nextVideoTimeStreamController.add(_nextVideoTime);
      });
    }
  }

  void cancelNextVideoTimer() {
    _nextVideoTime = null;
    nextVideoTimeStreamController.add(_nextVideoTime);
    _nextVideoTimer?.cancel();
    _nextVideoTimer = null;
  }

  void playNextVideo() {
    _nextVideoTime = 0;
    nextVideoTimeStreamController.add(_nextVideoTime);
    cancelNextVideoTimer();
  }

  @override
  void dispose() {
    _eventListeners.clear();
    videoPlayerController?.removeListener(_fullScreenListener);
    videoPlayerController?.removeListener(_onVideoPlayerChanged);
    videoPlayerController?.dispose();
    _nextVideoTimer?.cancel();
    nextVideoTimeStreamController.close();
    super.dispose();
  }
}
