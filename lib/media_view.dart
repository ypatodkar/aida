import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'api.dart';
import 'design.dart';

class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.mine,
    required this.api,
    this.receipt = 'Sent',
  });

  final Map<String, dynamic> message;
  final bool mine;
  final AidaApi api;
  final String receipt;

  @override
  Widget build(BuildContext context) {
    final kind = message['kind'] as String;
    final mediaId = message['mediaId'] as String?;
    Widget content;
    if (kind == 'image' && mediaId != null) {
      content = GestureDetector(
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => Dialog(
            child: InteractiveViewer(
              child: Image.network(
                api.mediaUrl(mediaId).toString(),
                headers: api.mediaHeaders,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            api.mediaUrl(mediaId).toString(),
            headers: api.mediaHeaders,
            width: 240,
            height: 220,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox(
              width: 240,
              height: 100,
              child: Center(child: Text('Image unavailable')),
            ),
          ),
        ),
      );
    } else if (kind == 'video' && mediaId != null) {
      content = InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VideoScreen(api: api, mediaId: mediaId),
          ),
        ),
        child: const SizedBox(
          width: 230,
          height: 120,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [Icon(Icons.play_circle, size: 50), Text('Play video')],
            ),
          ),
        ),
      );
    } else {
      content = Text(
        message['text']?.toString() ?? '',
        style: TextStyle(color: mine ? cream : ink, fontSize: 15, height: 1.5),
      );
    }
    final created = DateTime.fromMillisecondsSinceEpoch(
      message['createdAt'] as int,
    );
    final time =
        '${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')}';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .78,
        ),
        padding: const EdgeInsets.fromLTRB(15, 12, 15, 9),
        decoration: BoxDecoration(
          color: mine ? ink : Colors.white,
          border: mine ? null : Border.all(color: const Color(0xFFE8EAE2)),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(20),
            topRight: const Radius.circular(20),
            bottomLeft: Radius.circular(mine ? 20 : 5),
            bottomRight: Radius.circular(mine ? 5 : 20),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            DefaultTextStyle.merge(
              style: TextStyle(color: mine ? cream : ink),
              child: IconTheme(
                data: IconThemeData(color: mine ? cream : ink),
                child: content,
              ),
            ),
            const SizedBox(height: 5),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  time,
                  style: TextStyle(
                    fontSize: 9,
                    color: mine ? Colors.white54 : muted,
                  ),
                ),
                if (mine) ...[
                  const SizedBox(width: 4),
                  Tooltip(
                    message: receipt,
                    child: Icon(
                      receipt == 'Sent'
                          ? Icons.check_rounded
                          : Icons.done_all_rounded,
                      semanticLabel: receipt,
                      size: 14,
                      color: receipt == 'Read'
                          ? const Color(0xFF8FDFB4)
                          : Colors.white54,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, required this.api, required this.mediaId});

  final AidaApi api;
  final String mediaId;

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  late final VideoPlayerController _controller;
  late final Future<void> _ready;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(
      widget.api.mediaUrl(widget.mediaId),
      httpHeaders: widget.api.mediaHeaders,
    );
    _ready = _controller.initialize().then((_) => _controller.play());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Video')),
      body: Center(
        child: FutureBuilder<void>(
          future: _ready,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Text('Video unavailable');
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return const CircularProgressIndicator();
            }
            return GestureDetector(
              onTap: () {
                setState(() {
                  if (_controller.value.isPlaying) {
                    _controller.pause();
                  } else {
                    _controller.play();
                  }
                });
              },
              child: AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              ),
            );
          },
        ),
      ),
    );
  }
}
