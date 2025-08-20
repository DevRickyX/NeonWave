// lib/controllers/crossfade_engine.dart
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

class Track {
  final String title;
  final Uri uri;
  final String? filePath;
  Track({required this.title, required this.uri, this.filePath});
}

enum SimpleLoopMode { off, all, one }

/// Motor de reproducción con crossfade real usando dos AudioPlayer.
/// Compatible con just_audio 0.10.x (no usa setCrossfadeDuration ni crossfadeDurationStream).
class CrossfadeEngine {
  final AudioPlayer _a = AudioPlayer();
  final AudioPlayer _b = AudioPlayer();
  bool _usingA = true;

  List<Track> _playlist = [];
  int _index = 0;

  bool _shuffle = false;
  SimpleLoopMode _loop = SimpleLoopMode.off;

  Duration _crossfade = const Duration(seconds: 4);

  // Subs
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;

  // Streams a la UI
  final _titleCtrl = StreamController<String>.broadcast();
  final _indexCtrl = StreamController<int>.broadcast();
  final _playingCtrl = StreamController<bool>.broadcast();
  final _positionCtrl = StreamController<Duration>.broadcast();
  final _durationCtrl = StreamController<Duration?>.broadcast();
  final _crossfadeCtrl = StreamController<int>.broadcast();

  Stream<String> get titleStream => _titleCtrl.stream;
  Stream<int> get indexStream => _indexCtrl.stream;
  Stream<bool> get playingStream => _playingCtrl.stream;
  Stream<Duration> get positionStream => _positionCtrl.stream;
  Stream<Duration?> get durationStream => _durationCtrl.stream;
  Stream<int> get crossfadeSecondsStream => _crossfadeCtrl.stream;

  List<Track> get playlist => _playlist;
  int get currentIndex => _index;
  bool get isPlaying => _current.playing;
  bool get shuffleEnabled => _shuffle;
  SimpleLoopMode get loopMode => _loop;
  int get crossfadeSeconds => _crossfade.inSeconds;

  AudioPlayer get _current => _usingA ? _a : _b;
  AudioPlayer get _standby => _usingA ? _b : _a;

  Future<void> initSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  }

  Future<void> setPlaylist(List<Track> tracks, {int startIndex = 0}) async {
    _playlist = List<Track>.from(tracks);
    final upper = _playlist.isEmpty ? 0 : _playlist.length - 1;
    _index = startIndex.clamp(0, upper).toInt();
    await _loadCurrentAndPlay(resume: false);
  }

  Future<void> _loadCurrentAndPlay({bool resume = true}) async {
    if (_playlist.isEmpty) return;
    await _stopBoth();

    final t = _playlist[_index];
    await _current.setAudioSource(
      AudioSource.uri(
        t.uri,
        tag: MediaItem(
          id: t.uri.toString(),
          album: 'Local files',
          title: t.title,
          artUri: null, // Si tienes carátula, pon el Uri aquí
        ),
      ),
      preload: true,
    );
    await _current.setVolume(1.0);
    if (resume) {
      await _current.play();
    }

    _emitMeta();
    _bindToCurrentPlayer();
  }

  void _emitMeta() {
    if (_playlist.isEmpty) return;
    _titleCtrl.add(_playlist[_index].title);
    _indexCtrl.add(_index);
  }

  void _bindToCurrentPlayer() {
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();

    _posSub = _current.positionStream.listen((pos) async {
      _positionCtrl.add(pos);
      final d = _current.duration;
      if (d == null) return;
      final remaining = d - pos;
      if (_crossfade > Duration.zero && remaining <= _crossfade) {
        _posSub?.cancel();
        await _startCrossfadeToNext(auto: true);
      }
    });

    _durSub = _current.durationStream.listen((d) {
      _durationCtrl.add(d);
    });

    _stateSub = _current.playerStateStream.listen((s) async {
      _playingCtrl.add(s.playing);
      if (s.processingState == ProcessingState.completed) {
        await _advanceAfterEnd();
      }
    });
  }

  Future<void> _advanceAfterEnd() async {
    if (_playlist.isEmpty) return;
    if (_loop == SimpleLoopMode.one) {
      await seek(Duration.zero);
      await _current.play();
      return;
    }
    final length = _playlist.length;
    final next = (_index + 1 < length) ? _index + 1 : -1;
    if (next >= 0) {
      _index = next;
      await _loadCurrentAndPlay();
    } else {
      if (_loop == SimpleLoopMode.all) {
        _index = 0;
        await _loadCurrentAndPlay();
      } else {
        await pause();
      }
    }
  }

  Future<void> _startCrossfadeToNext({bool auto = false}) async {
    if (_playlist.isEmpty) return;

    int next = _index + 1;
    final length = _playlist.length;
    if (next >= length) {
      if (_loop == SimpleLoopMode.all) {
        next = 0;
      } else if (_loop == SimpleLoopMode.off) {
        if (auto) return; // fin automático sin siguiente
        next = _index;     // manual: cruza consigo mismo
      } else {
        next = _index;     // loop one
      }
    }

    final tNext = _playlist[next];
    await _standby.setAudioSource(
      AudioSource.uri(
        tNext.uri,
        tag: MediaItem(
          id: tNext.uri.toString(),
          album: 'Local files',
          title: tNext.title,
          artUri: null,
        ),
      ),
      preload: true,
    );
    await _standby.setVolume(0.0);
    await _standby.play();

    const int steps = 24;
    int stepMs = (_crossfade.inMilliseconds / steps).round();
    if (stepMs < 10) stepMs = 10;
    if (stepMs > 200) stepMs = 200;

    for (int i = 0; i <= steps; i++) {
      final double t = i / steps;
      _current.setVolume(1.0 - t);
      _standby.setVolume(t);
      await Future.delayed(Duration(milliseconds: stepMs));
    }

    await _current.stop();

    _usingA = !_usingA;
    _index = next;
    _emitMeta();
    _bindToCurrentPlayer();
  }

  // Controles básicos
  Future<void> play() async => _current.play();
  Future<void> pause() async => _current.pause();

  Future<void> togglePlayPause() async {
    if (_current.playing) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seek(Duration pos) async => _current.seek(pos);

  Future<void> playIndex(int i) async {
    if (_playlist.isEmpty) return;
    final upper = _playlist.length - 1;
    _index = i.clamp(0, upper).toInt();
    await _loadCurrentAndPlay();
  }

  Future<void> seekToNext({bool useCrossfade = true}) async {
    if (!useCrossfade || _crossfade == Duration.zero) {
      final length = _playlist.isEmpty ? 1 : _playlist.length;
      final int next = (_index + 1) % length;
      await playIndex(next);
      return;
    }
    await _startCrossfadeToNext(auto: false);
  }

  Future<void> seekToPrevious({bool useCrossfade = true}) async {
    if (!useCrossfade || _crossfade == Duration.zero) {
      int prev = _index - 1;
      if (prev < 0) {
        prev = _playlist.isEmpty ? 0 : _playlist.length - 1;
      }
      await playIndex(prev);
      return;
    }

    int prev = _index - 1;
    if (prev < 0) {
      prev = (_loop == SimpleLoopMode.all && _playlist.isNotEmpty)
          ? _playlist.length - 1
          : _index;
    }

    final tPrev = _playlist[prev];
    await _standby.setAudioSource(
      AudioSource.uri(
        tPrev.uri,
        tag: MediaItem(
          id: tPrev.uri.toString(),
          album: 'Local files',
          title: tPrev.title,
          artUri: null,
        ),
      ),
      preload: true,
    );
    await _standby.setVolume(0.0);
    await _standby.play();

    const int steps = 24;
    int stepMs = (_crossfade.inMilliseconds / steps).round();
    if (stepMs < 10) stepMs = 10;
    if (stepMs > 200) stepMs = 200;

    for (int i = 0; i <= steps; i++) {
      final double t = i / steps;
      _current.setVolume(1.0 - t);
      _standby.setVolume(t);
      await Future.delayed(Duration(milliseconds: stepMs));
    }

    await _current.stop();
    _usingA = !_usingA;
    _index = prev;
    _emitMeta();
    _bindToCurrentPlayer();
  }

  Future<void> setShuffle(bool enabled) async {
    _shuffle = enabled;
    if (_playlist.length <= 1) return;

    final current = _playlist[_index];
    final rest = List<Track>.from(_playlist)..removeAt(_index);
    rest.shuffle();
    _playlist = [current, ...rest];
    _index = 0;
    _emitMeta();
  }

  Future<void> cycleLoopMode() async {
    if (_loop == SimpleLoopMode.off) {
      _loop = SimpleLoopMode.all;
    } else if (_loop == SimpleLoopMode.all) {
      _loop = SimpleLoopMode.one;
    } else {
      _loop = SimpleLoopMode.off;
    }
  }

  Future<void> setCrossfadeSeconds(int s) async {
    final int v = s.clamp(0, 10).toInt();
    _crossfade = Duration(seconds: v);
    _crossfadeCtrl.add(_crossfade.inSeconds);
  }

  Future<void> _stopBoth() async {
    await _a.stop();
    await _b.stop();
    await _a.setVolume(1.0);
    await _b.setVolume(1.0);
  }

  Future<void> dispose() async {
    await _posSub?.cancel();
    await _durSub?.cancel();
    await _stateSub?.cancel();
    await _a.dispose();
    await _b.dispose();
    await _titleCtrl.close();
    await _indexCtrl.close();
    await _playingCtrl.close();
    await _positionCtrl.close();
    await _durationCtrl.close();
    await _crossfadeCtrl.close();
  }
}
