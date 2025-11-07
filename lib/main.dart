import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'controllers/crossfade_engine.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializa la notificación/servicio en background
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.neonwave.player.audio',
    androidNotificationChannelName: 'Neonwave Playback',
    androidNotificationOngoing: true,
    androidShowNotificationBadge: false,
  );

  runApp(const NeonPlayerApp());
}

class NeonPlayerApp extends StatelessWidget {
  const NeonPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Neonwave',
      theme: base.copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0B10),
        colorScheme: base.colorScheme.copyWith(
          primary: const Color(0xFF6C9BF5),
          secondary: const Color(0xFF00FFC6),
          tertiary: const Color(0xFFFF2E9E),
        ),
        sliderTheme: base.sliderTheme.copyWith(
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
        ),
        iconTheme: base.iconTheme.copyWith(size: 26),
        textTheme: base.textTheme.apply(
          bodyColor: Colors.white,
          displayColor: Colors.white,
        ),
      ),
      home: const LibraryPage(),
    );
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final CrossfadeEngine engine = CrossfadeEngine();
  String? pickedFolder;
  bool loading = false;
  bool includeSubfolders = false;

  static const _audioExts = {
    '.mp3',
    '.m4a',
    '.aac',
    '.flac',
    '.ogg',
    '.opus',
    '.wav',
  };

  @override
  void initState() {
    super.initState();
    engine.initSession();
    engine.setCrossfadeSeconds(4);
  }

  @override
  void dispose() {
    engine.dispose();
    super.dispose();
  }

  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) return;
    await [
      Permission.storage, // legacy
      Permission.audio, // Android 13+ READ_MEDIA_AUDIO
      Permission.notification, // Android 13+ para mostrar la notificación
    ].request();
  }

  bool _isAudioFile(String path) {
    final ext = p.extension(path).toLowerCase();
    return _audioExts.contains(ext);
  }

  Iterable<FileSystemEntity> _listFilesSync(
    Directory dir, {
    bool recursive = false,
  }) sync* {
    final lister = dir.listSync(recursive: recursive, followLinks: false);
    for (final e in lister) {
      if (e is File && _isAudioFile(e.path)) yield e;
    }
  }

  Future<void> _pickFolder() async {
    setState(() => loading = true);
    try {
      await _ensurePermissions();

      final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select music folder',
        lockParentWindow: false,
      );
      if (path == null) {
        setState(() => loading = false);
        return;
      }

      final dir = Directory(path);
      if (!(await dir.exists())) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Folder not accessible.')),
          );
        }
        setState(() => loading = false);
        return;
      }

      final files = _listFilesSync(dir, recursive: includeSubfolders).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      if (files.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No audio files found in this folder.'),
            ),
          );
        }
        setState(() {
          pickedFolder = path;
          loading = false;
        });
        return;
      }

      final tracks = files.map((f) {
        final name = p.basenameWithoutExtension(f.path);
        final uri = Uri.file(f.path);
        return Track(title: name, uri: uri, filePath: f.path);
      }).toList();

      await engine.setPlaylist(tracks);

      setState(() {
        pickedFolder = path;
        loading = false;
      });

      if (mounted) {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => PlayerPage(engine: engine)));
      }
    } catch (e) {
      setState(() => loading = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  void _goToPlayerTapped() {
    if (engine.playlist.isEmpty) {
      // Si aún no hay playlist, te ofrezco dos opciones:
      // A) Mostrar un aviso:
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Primero elige una carpeta de música')),
      );
      // B) O lanzar directamente el selector de carpeta:
      // _pickFolder();
      return;
    }

    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => PlayerPage(engine: engine)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.0, -0.4),
                  radius: 1.0,
                  colors: [
                    cs.tertiary.withOpacity(0.12),
                    cs.secondary.withOpacity(0.08),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: GridLinesPainter(color: Colors.white.withOpacity(0.05)),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Neonwave',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      foreground: Paint()
                        ..shader = LinearGradient(
                          colors: [cs.primary, cs.tertiary],
                        ).createShader(const Rect.fromLTWH(0, 0, 220, 40)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Select a folder to start playing your music.\nBold, modern, crossfading bliss 🎧',
                    style: TextStyle(color: Colors.white.withOpacity(0.75)),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      FilterChip(
                        label: const Text('Include subfolders'),
                        selected: includeSubfolders,
                        onSelected: (v) =>
                            setState(() => includeSubfolders = v),
                      ),
                      const SizedBox(width: 12),
                      if (pickedFolder != null)
                        Expanded(
                          child: Text(
                            pickedFolder!,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.7),
                            ),
                            textAlign: TextAlign.right,
                          ),
                        ),
                    ],
                  ),
                  const Spacer(),
                  Center(
                    child: SizedBox(
                      width: 220,
                      height: 220,
                      child: Material(
                        color: Colors.transparent,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _goToPlayerTapped,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: SweepGradient(
                                colors: [
                                  cs.primary.withOpacity(0.85),
                                  cs.secondary.withOpacity(0.85),
                                  cs.tertiary.withOpacity(0.85),
                                  cs.primary.withOpacity(0.85),
                                ],
                                stops: const [0.0, 0.33, 0.66, 1.0],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: cs.primary.withOpacity(0.35),
                                  blurRadius: 30,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.music_note,
                                size: 80,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),
                  Center(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: cs.tertiary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: loading ? null : _pickFolder,
                      icon: const Icon(Icons.folder_open),
                      label: Text(loading ? 'Loading…' : 'Choose music folder'),
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PlayerPage extends StatefulWidget {
  final CrossfadeEngine engine;
  const PlayerPage({super.key, required this.engine});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController discCtrl;
  late final StreamSubscription<bool> _playingSub;
  bool isPlaying = false;

  @override
  void initState() {
    super.initState();
    discCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );
    _playingSub = widget.engine.playingStream.listen((playing) {
      setState(() => isPlaying = playing);
      if (playing) {
        discCtrl.repeat();
      } else {
        discCtrl.stop();
      }
    });
  }

  @override
  void dispose() {
    _playingSub.cancel();
    discCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final e = widget.engine;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Now Playing'),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: const Alignment(-0.8, -1.0),
                  end: const Alignment(1.0, 0.8),
                  colors: [
                    cs.primary.withOpacity(0.15),
                    cs.secondary.withOpacity(0.10),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: GridLinesPainter(color: Colors.white.withOpacity(0.04)),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
              child: Column(
                children: [
                  // Título actual
                  StreamBuilder<String>(
                    stream: e.titleStream,
                    builder: (context, snap) {
                      final title = snap.data ?? '—';
                      return Text(
                        title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      );
                    },
                  ),

                  const SizedBox(height: 20),

                  // Disco giratorio
                  SizedBox(
                    width: 280,
                    height: 280,
                    child: AnimatedBuilder(
                      animation: discCtrl,
                      builder: (context, child) {
                        return Transform.rotate(
                          angle: discCtrl.value * 6.28318530718,
                          child: child,
                        );
                      },
                      child: _NeonDisc(),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Seekbar
                  StreamBuilder<Duration?>(
                    stream: e.durationStream,
                    builder: (context, dSnap) {
                      final total = dSnap.data ?? Duration.zero;
                      return StreamBuilder<Duration>(
                        stream: e.positionStream,
                        builder: (context, pSnap) {
                          final pos = pSnap.data ?? Duration.zero;
                          return Column(
                            children: [
                              Slider(
                                value: pos.inMilliseconds
                                    .clamp(0, total.inMilliseconds)
                                    .toDouble(),
                                max: (total.inMilliseconds == 0)
                                    ? 1
                                    : total.inMilliseconds.toDouble(),
                                onChanged: (v) {},
                                onChangeEnd: (v) =>
                                    e.seek(Duration(milliseconds: v.round())),
                              ),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    _fmt(pos),
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.8),
                                    ),
                                  ),
                                  Text(
                                    _fmt(total),
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.6),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),

                  const SizedBox(height: 14),

                  // Controles
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Shuffle',
                        icon: Icon(
                          e.shuffleEnabled ? Icons.shuffle_on : Icons.shuffle,
                        ),
                        onPressed: () async {
                          await e.setShuffle(!e.shuffleEnabled);
                          setState(() {});
                        },
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: 'Previous',
                        icon: const Icon(Icons.skip_previous_rounded),
                        onPressed: () => e.seekToPrevious(useCrossfade: true),
                      ),
                      const SizedBox(width: 6),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isPlaying
                              ? cs.tertiary
                              : cs.secondary,
                          shape: const CircleBorder(),
                          padding: const EdgeInsets.all(16),
                        ),
                        onPressed: () => e.togglePlayPause(),
                        child: Icon(
                          isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 36,
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: 'Next',
                        icon: const Icon(Icons.skip_next_rounded),
                        onPressed: () => e.seekToNext(useCrossfade: true),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: 'Repeat',
                        icon: Icon(
                          e.loopMode == SimpleLoopMode.one
                              ? Icons.repeat_one_on
                              : (e.loopMode == SimpleLoopMode.all
                                    ? Icons.repeat_on
                                    : Icons.repeat_rounded),
                        ),
                        onPressed: () async {
                          await e.cycleLoopMode();
                          setState(() {});
                        },
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),

                  // Crossfade slider (0-10s)
                  Card(
                    color: Colors.white.withOpacity(0.04),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Crossfade',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          StreamBuilder<int>(
                            stream: e.crossfadeSecondsStream,
                            initialData: e.crossfadeSeconds,
                            builder: (context, snap) {
                              final current = (snap.data ?? 0).toDouble();
                              return Column(
                                children: [
                                  Slider(
                                    min: 0,
                                    max: 10,
                                    value: current.clamp(0, 10),
                                    onChanged: (v) {},
                                    onChangeEnd: (v) async {
                                      await e.setCrossfadeSeconds(v.round());
                                    },
                                  ),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      '${current.round()} s',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.7),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Playlist
                  Expanded(
                    child: StreamBuilder<int>(
                      stream: e.indexStream,
                      initialData: e.currentIndex,
                      builder: (context, snap) {
                        final idx = snap.data ?? 0;
                        final seq = e.playlist;
                        if (seq.isEmpty) {
                          return Center(
                            child: Text(
                              'No tracks loaded',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.7),
                              ),
                            ),
                          );
                        }
                        return ListView.builder(
                          itemCount: seq.length,
                          itemBuilder: (context, i) {
                            final title = seq[i].title;
                            final selected = i == idx;
                            return ListTile(
                              dense: true,
                              title: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: selected ? cs.secondary : Colors.white,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                              leading: Icon(
                                selected
                                    ? Icons.graphic_eq
                                    : Icons.audiotrack_rounded,
                                color: selected ? cs.secondary : Colors.white70,
                              ),
                              onTap: () => e.playIndex(i),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

class _NeonDisc extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [Colors.black, Colors.black, Colors.transparent],
          stops: [0.0, 0.82, 1.0],
        ),
      ),
      child: Stack(
        children: [
          ...List.generate(5, (i) {
            final inset = 20.0 + i * 16.0;
            return Positioned.fill(
              child: Padding(
                padding: EdgeInsets.all(inset),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withOpacity(0.05 + i * 0.03),
                      width: 1.2,
                    ),
                  ),
                ),
              ),
            );
          }),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  width: 6,
                  color: cs.tertiary.withOpacity(0.65),
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [cs.secondary, cs.primary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: cs.secondary.withOpacity(0.4),
                    blurRadius: 16,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Center(
                child: Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.black87,
                  size: 36,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GridLinesPainter extends CustomPainter {
  final Color color;
  GridLinesPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const spacing = 32.0;
    for (double x = 0; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant GridLinesPainter oldDelegate) => false;
}
