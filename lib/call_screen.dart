import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';

import 'api.dart';
import 'design.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.api,
    required this.call,
    required this.partnerName,
    required this.myId,
  });
  final AidaApi api;
  final Map<String, dynamic> call;
  final String partnerName;
  final String myId;
  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  static const _audio = MethodChannel('aida/call_audio');
  Room? _room;
  LocalVideoTrack? _preview;
  Future<void>? _previewReady;
  Timer? _poll;
  bool _checking = false;
  bool _joining = false;
  bool _joined = false;
  bool _ending = false;
  bool _mic = true;
  bool _camera = true;
  bool _speaker = false;
  bool _front = true;
  late String _state;
  String? _error;
  DateTime? _connectedAt;
  bool get _video => widget.call['kind'] == 'video';
  bool get _incoming => widget.call['initiatorId'] != widget.myId;

  @override
  void initState() {
    super.initState();
    _state = widget.call['state'] as String;
    _speaker = _video;
    if (_video && (!_incoming || _state == 'active')) {
      _previewReady = _startPreview();
    }
    if (_state == 'active') {
      _join();
    } else {
      _audio
          .invokeMethod<void>('start', {'incoming': _incoming})
          .catchError((_) {});
    }
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => _check());
  }

  Future<void> _startPreview() async {
    try {
      final track = await LocalVideoTrack.createCameraTrack(
        const CameraCaptureOptions(cameraPosition: CameraPosition.front),
      );
      if (!mounted || _ending) {
        await track.stop();
        await track.dispose();
        return;
      }
      setState(() {
        _preview = track;
        _camera = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _camera = false;
          _error = 'Camera unavailable. Allow camera access in Android settings, then tap the camera button to retry.';
        });
      }
    }
  }

  Future<void> _join() async {
    if (_joining || _joined || _ending) return;
    _joining = true;
    await _audio.invokeMethod<void>('stop').catchError((_) {});
    try {
      if (_video && _previewReady == null) _previewReady = _startPreview();
      await _previewReady;
      final credentials = await widget.api.joinCall(
        widget.call['id'] as String,
      );
      if (!mounted || _ending) return;
      final room = Room(
        roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true),
      );
      _room = room;
      room.addListener(_changed);
      await room.connect(
        credentials['url'] as String,
        credentials['token'] as String,
      );
      if (!mounted || _ending) {
        await room.disconnect();
        return;
      }
      try {
        await room.localParticipant?.setMicrophoneEnabled(_mic);
      } catch (_) {
        _mic = false;
        _error = 'Microphone unavailable. Allow microphone access in Android settings.';
      }
      if (_preview != null && _camera) {
        await room.localParticipant?.publishVideoTrack(_preview!);
      }
      await AudioManager.instance.setSpeakerOutputPreferred(_speaker);
      await _audio
          .invokeMethod<void>('active', {'video': _video && _camera})
          .catchError((_) {});
      if (mounted) {
        setState(() {
          _joined = true;
          _connectedAt = DateTime.now();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'The call could not connect. Check your network and tap Retry.',
        );
      }
      final room = _room;
      room?.removeListener(_changed);
      if (room != null) {
        await room.disconnect();
        await room.dispose();
      }
      _room = null;
      _preview = null;
      _previewReady = null;
    } finally {
      _joining = false;
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _check() async {
    if (_checking || _ending) return;
    _checking = true;
    try {
      final call =
          (await widget.api.currentCall())['call'] as Map<String, dynamic>?;
      if (!mounted || _ending) return;
      if (call == null || call['id'] != widget.call['id']) {
        await _finish();
        return;
      }
      final changed = _state != call['state'];
      setState(() => _state = call['state'] as String);
      if (_state == 'active' && changed) await _join();
    } on ApiException catch (e) {
      if (e.status == 401 || e.status == 409) await _finish();
    } catch (_) {
    } finally {
      _checking = false;
    }
  }

  Future<void> _answer() async {
    try {
      await widget.api.callAction(widget.call['id'] as String, 'accept');
      if (mounted) setState(() => _state = 'active');
      await _join();
    } catch (_) {
      await _check();
    }
  }

  Future<void> _hangUp() async {
    if (_ending) return;
    setState(() => _ending = true);
    await _audio.invokeMethod<void>('stop').catchError((_) {});
    try {
      await widget.api.callAction(
        widget.call['id'] as String,
        _incoming && _state == 'ringing' ? 'decline' : 'end',
      );
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  Future<void> _finish() async {
    if (_ending) return;
    setState(() => _ending = true);
    await _audio.invokeMethod<void>('stop').catchError((_) {});
    if (mounted) Navigator.pop(context);
  }

  Future<void> _toggleCamera() async {
    try {
      if (_preview == null) {
        _previewReady = _startPreview();
        await _previewReady;
        if (_preview == null) return;
        _camera = true;
        if (_joined) {
          await _room?.localParticipant?.publishVideoTrack(_preview!);
        }
      } else {
        _camera ? await _preview!.mute() : await _preview!.unmute();
        _camera = !_camera;
      }
      if (_joined &&
          _camera &&
          _preview != null &&
          _room?.localParticipant?.videoTrackPublications.any(
                (p) => p.track == _preview,
              ) !=
              true) {
        await _room?.localParticipant?.publishVideoTrack(_preview!);
      }
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not change the camera. Try again.');
      }
    }
  }

  VideoTrack? _remoteVideo() {
    for (final person
        in _room?.remoteParticipants.values ?? <RemoteParticipant>[]) {
      for (final p in person.videoTrackPublications) {
        if (!p.muted && p.track is VideoTrack) return p.track as VideoTrack;
      }
    }
    return null;
  }

  @override
  void dispose() {
    _poll?.cancel();
    unawaited(_audio.invokeMethod<void>('stop').catchError((_) {}));
    unawaited(_audio.invokeMethod<void>('endCall').catchError((_) {}));
    _room?.removeListener(_changed);
    final room = _room;
    final preview = _preview;
    unawaited(() async {
      if (room != null) {
        await room.disconnect();
        await room.dispose();
      }
      if (preview != null) {
        await preview.stop();
        await preview.dispose();
      }
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remote = _remoteVideo();
    final connected = _room?.remoteParticipants.isNotEmpty == true;
    final seconds = _connectedAt == null
        ? 0
        : DateTime.now().difference(_connectedAt!).inSeconds;
    final duration =
        '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
    final status = _state == 'ringing'
        ? (_incoming
              ? 'Incoming ${_video ? 'video' : 'voice'} call'
              : 'Ringing…')
        : !_joined
        ? 'Connecting…'
        : !connected
        ? 'Waiting for ${widget.partnerName}…'
        : duration;
    return PopScope(
      canPop: _ending,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _hangUp();
      },
      child: Scaffold(
        backgroundColor: night,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.link_rounded, color: apricot, size: 22),
                    const SizedBox(width: 10),
                    const Text(
                      'aida',
                      style: TextStyle(
                        fontFamily: serif,
                        color: nightText,
                        fontSize: 25,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _video ? 'VIDEO CALL' : 'VOICE CALL',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 10,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: remote != null
                              ? VideoTrackRenderer(
                                  remote,
                                  fit: VideoViewFit.cover,
                                )
                              : Container(
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [nightRaised, night],
                                    ),
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      PersonAvatar(
                                        widget.partnerName,
                                        size: 108,
                                        dark: true,
                                      ),
                                      const SizedBox(height: 24),
                                      Text(
                                        widget.partnerName,
                                        style: const TextStyle(
                                          fontFamily: serif,
                                          color: nightText,
                                          fontSize: 34,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        status,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                        if (remote != null)
                          Positioned(
                            left: 20,
                            top: 20,
                            child: Chip(label: Text(status)),
                          ),
                        if (_video && (!_incoming || _state == 'active'))
                          Positioned(
                            right: 16,
                            bottom: 16,
                            width: 112,
                            height: 160,
                            child: Container(
                              clipBehavior: Clip.antiAlias,
                              decoration: BoxDecoration(
                                color: nightControl,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: Colors.white30,
                                  width: 2,
                                ),
                              ),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (_preview != null && _camera)
                                    VideoTrackRenderer(
                                      _preview!,
                                      fit: VideoViewFit.cover,
                                    )
                                  else
                                    Center(
                                      child: Icon(
                                        _camera
                                            ? Icons.camera_alt_outlined
                                            : Icons.videocam_off,
                                        color: Colors.white60,
                                      ),
                                    ),
                                  const Positioned(
                                    left: 10,
                                    bottom: 8,
                                    child: Text(
                                      'You',
                                      style: TextStyle(
                                        color: Colors.white,
                                        shadows: [Shadow(blurRadius: 4)],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                  child: Column(
                    children: [
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: apricot, fontSize: 12),
                      ),
                      if (!_joined && _state == 'active')
                        TextButton(
                          onPressed: _joining ? null : _join,
                          child: const Text(
                            'Retry',
                            style: TextStyle(color: nightText),
                          ),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 24,
                ),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    if (_incoming && _state == 'ringing')
                      _control(
                        Icons.call,
                        'Answer',
                        _answer,
                        color: answerGreen,
                      )
                    else ...[
                      _control(
                        _mic ? Icons.mic : Icons.mic_off,
                        _mic ? 'Mute' : 'Unmute',
                        () async {
                          try {
                            await _room?.localParticipant?.setMicrophoneEnabled(
                              !_mic,
                            );
                            if (mounted) setState(() => _mic = !_mic);
                          } catch (_) {
                            if (mounted) {
                              setState(
                                () => _error =
                                    'Microphone permission is needed to speak.',
                              );
                            }
                          }
                        },
                      ),
                      if (_video)
                        _control(
                          _camera ? Icons.videocam : Icons.videocam_off,
                          'Camera',
                          _toggleCamera,
                        ),
                      if (_video)
                        _control(
                          Icons.flip_camera_ios_outlined,
                          'Flip',
                          () async {
                            try {
                              await _preview?.setCameraPosition(
                                _front
                                    ? CameraPosition.back
                                    : CameraPosition.front,
                              );
                              _front = !_front;
                            } catch (_) {}
                          },
                        )
                      else
                        _control(
                          _speaker ? Icons.volume_up : Icons.hearing,
                          'Speaker',
                          () async {
                            try {
                              await AudioManager.instance
                                  .setSpeakerOutputPreferred(!_speaker);
                              if (mounted) setState(() => _speaker = !_speaker);
                            } catch (_) {}
                          },
                        ),
                    ],
                    _control(
                      Icons.call_end,
                      _incoming && _state == 'ringing' ? 'Decline' : 'End',
                      _hangUp,
                      color: endRed,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _control(
    IconData icon,
    String label,
    VoidCallback action, {
    Color color = nightControl,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton.filled(
        onPressed: _ending ? null : action,
        style: IconButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          fixedSize: const Size(56, 56),
        ),
        icon: Icon(icon),
      ),
      const SizedBox(height: 8),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
    ],
  );
}
