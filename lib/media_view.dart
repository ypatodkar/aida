import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
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
    this.joinsAbove = false,
    this.joinsBelow = false,
    this.animate = false,
    this.highlighted = false,
    this.quoteAuthor = '',
    this.onReply,
    this.onOptions,
    this.onQuoteTap,
  });

  static const _textPadding = EdgeInsets.fromLTRB(14, 9, 12, 8);

  final Map<String, dynamic> message;
  final bool mine;
  final AidaApi api;
  final String receipt;

  /// Whether the neighbouring message is from the same person moments apart;
  /// grouped bubbles sit closer and soften the corners where they meet.
  final bool joinsAbove;
  final bool joinsBelow;
  final bool animate;

  /// Briefly tints the bubble after jumping to it from a reply.
  final bool highlighted;

  /// Display name of whoever wrote the message this one replies to.
  final String quoteAuthor;
  final VoidCallback? onReply;
  final VoidCallback? onOptions;
  final VoidCallback? onQuoteTap;

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    final kind = message['kind'] as String;
    final deleted = message['deleted'] == true;
    final mediaId = message['mediaId'] as String?;
    final media =
        !deleted && (kind == 'image' || kind == 'video') && mediaId != null;
    final kept = !deleted && message['kept'] == true;
    final reactions = deleted
        ? const <Map<String, dynamic>>[]
        : ((message['reactions'] as List?) ?? const [])
              .cast<Map<String, dynamic>>();
    final reply = deleted ? null : onReply;
    final options = deleted ? null : onOptions;
    final foreground = deleted ? c.muted : (mine ? c.onMine : c.ink);
    final created = DateTime.fromMillisecondsSinceEpoch(
      message['createdAt'] as int,
    );
    final clock =
        '${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')}';
    final time = !deleted && message['editedAt'] != null
        ? 'edited · $clock'
        : clock;
    final timeStyle = TextStyle(
      fontSize: 10,
      color: foreground.withValues(alpha: .62),
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final meta = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (kept) ...[
          Icon(
            Icons.bookmark_rounded,
            size: 11,
            color: foreground.withValues(alpha: .62),
            semanticLabel: 'Kept in Moments',
          ),
          const SizedBox(width: 3),
        ],
        Text(time, style: timeStyle),
        if (mine && !deleted) ...[
          const SizedBox(width: 4),
          Tooltip(
            message: receipt,
            child: Icon(
              receipt == 'Sent' ? Icons.check_rounded : Icons.done_all_rounded,
              semanticLabel: receipt,
              size: 14,
              color: receipt == 'Read'
                  ? c.read
                  : foreground.withValues(alpha: .62),
            ),
          ),
        ],
      ],
    );

    Widget content;
    if (deleted) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.block_rounded, size: 15, color: foreground),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              mine ? 'You deleted this message' : 'This message was deleted',
              style: TextStyle(
                color: foreground,
                fontSize: 14.5,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          const SizedBox(width: 10),
          meta,
        ],
      );
    } else if (kind == 'image' && mediaId != null) {
      content = GestureDetector(
        onTap: () => openPhoto(context, api, mediaId),
        child: Hero(
          tag: 'media-$mediaId',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.network(
              api.mediaUrl(mediaId).toString(),
              headers: api.mediaHeaders,
              width: 240,
              height: 260,
              fit: BoxFit.cover,
              frameBuilder: (_, child, frame, synchronous) => AnimatedOpacity(
                opacity: synchronous || frame != null ? 1 : 0,
                duration: const Duration(milliseconds: 280),
                child: child,
              ),
              errorBuilder: (_, _, _) => _MediaPlaceholder(
                icon: Icons.image_not_supported_outlined,
                label: 'Image unavailable',
                color: foreground,
                height: 120,
              ),
            ),
          ),
        ),
      );
    } else if (kind == 'video' && mediaId != null) {
      content = GestureDetector(
        onTap: () => openVideo(context, api, mediaId),
        child: _MediaPlaceholder(
          icon: Icons.play_arrow_rounded,
          label: 'Play video',
          color: foreground,
          height: 150,
          prominent: true,
        ),
      );
    } else {
      content = _textWithMeta(
        context,
        message['text']?.toString() ?? '',
        TextStyle(color: foreground, fontSize: 15.5, height: 1.42),
        meta,
        time,
        timeStyle,
        kept ? 14 : 0,
      );
    }

    final body = media
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              content,
              const SizedBox(height: 4),
              Padding(padding: const EdgeInsets.only(right: 8), child: meta),
            ],
          )
        : content;
    final quote = deleted || message['replyToId'] == null
        ? null
        : ReplyQuote(
            quoted: message['replyTo'] as Map<String, dynamic>?,
            author: quoteAuthor,
            inMine: mine,
            onTap: onQuoteTap,
          );

    const round = Radius.circular(20);
    const tight = Radius.circular(6);
    final base = deleted ? c.background : (mine ? c.mine : c.theirs);
    final gapBelow = joinsBelow ? 3.0 : 14.0;
    final bubble = AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
      margin: EdgeInsets.only(bottom: reactions.isEmpty ? gapBelow : 0),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * .78,
      ),
      padding: media ? const EdgeInsets.fromLTRB(4, 4, 4, 6) : _textPadding,
      decoration: BoxDecoration(
        color: !highlighted
            ? base
            : mine
            ? Color.lerp(base, c.onMine, .22)
            : Color.lerp(base, c.accent, .16),
        border: mine && !deleted ? null : Border.all(color: c.border),
        borderRadius: BorderRadius.only(
          topLeft: !mine && joinsAbove ? tight : round,
          topRight: mine && joinsAbove ? tight : round,
          bottomLeft: mine ? round : tight,
          bottomRight: mine ? tight : round,
        ),
      ),
      child: quote == null
          ? body
          : media
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 240, child: quote),
                const SizedBox(height: 4),
                body,
              ],
            )
          // The quote and the text share one width: whichever is wider.
          : IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [quote, const SizedBox(height: 6), body],
              ),
            ),
    );

    final held = Semantics(
      customSemanticsActions: reply == null
          ? null
          : {const CustomSemanticsAction(label: 'Reply'): reply},
      onLongPressHint: options == null ? null : 'Message options',
      child: GestureDetector(onLongPress: options, child: bubble),
    );
    final aligned = SwipeToReply(
      onReply: reply,
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: reactions.isEmpty
            ? held
            : Column(
                crossAxisAlignment: mine
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  held,
                  // Tucked under the bubble's edge, as in most messengers.
                  Transform.translate(
                    offset: const Offset(0, -7),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: ReactionPill(reactions: reactions, onTap: options),
                    ),
                  ),
                  // The lifted pill still takes its full height in layout,
                  // which already leaves 7px below it.
                  SizedBox(height: joinsBelow ? 0 : gapBelow - 7),
                ],
              ),
      ),
    );
    if (!animate) return aligned;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - t)),
          child: Transform.scale(
            scale: .97 + .03 * t,
            alignment: mine ? Alignment.bottomRight : Alignment.bottomLeft,
            child: child,
          ),
        ),
      ),
      child: aligned,
    );
  }

  /// Message text with the time tucked into the end of its last line when
  /// there is room, or on a line of its own when there isn't. The text stays
  /// left-aligned even when a wider quote stretches the bubble.
  Widget _textWithMeta(
    BuildContext context,
    String text,
    TextStyle style,
    Widget meta,
    String time,
    TextStyle timeStyle,
    double extraMeta,
  ) {
    const gap = 10.0;
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final inherited = DefaultTextStyle.of(context).style;
    final stamp = TextPainter(
      text: TextSpan(text: time, style: inherited.merge(timeStyle)),
      textDirection: direction,
      textScaler: scaler,
    )..layout();
    final metaWidth = stamp.width + (mine ? 18 : 0) + extraMeta;
    final metaHeight = stamp.height > 14 ? stamp.height : 14.0;
    stamp.dispose();
    final maxWidth =
        MediaQuery.sizeOf(context).width * .78 - _textPadding.horizontal;
    final body = TextPainter(
      text: TextSpan(text: text, style: inherited.merge(style)),
      textDirection: direction,
      textScaler: scaler,
    )..layout(maxWidth: maxWidth);
    final lines = body.computeLineMetrics();
    final lastLine = lines.isEmpty ? 0.0 : lines.last.width;
    body.dispose();
    // A little slack absorbs rounding between the measurement and layout.
    final inline = lastLine + gap + metaWidth + 4 <= maxWidth;
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.only(bottom: inline ? 0 : metaHeight + 2),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: inline ? lastLine + gap + metaWidth + 4 : metaWidth,
            ),
            child: Text(text, style: style),
          ),
        ),
        Positioned(right: 0, bottom: 1, child: meta),
      ],
    );
  }
}

/// One-line description of a message for quotes, the reply bar, and menus.
String messageSnippet(Map<String, dynamic>? message) {
  if (message == null) return 'Message unavailable';
  if (message['deleted'] == true) return 'Message deleted';
  return switch (message['kind']) {
    'image' => 'Photo',
    'video' => 'Video',
    _ => (message['text']?.toString() ?? '').replaceAll(RegExp(r'\s+'), ' '),
  };
}

IconData? snippetIcon(Map<String, dynamic>? message) =>
    message?['deleted'] == true
    ? null
    : switch (message?['kind']) {
        'image' => Icons.photo_outlined,
        'video' => Icons.videocam_outlined,
        _ => null,
      };

/// The quick reactions offered when pressing and holding a message.
const reactionChoices = ['❤️', '😂', '😮', '😢', '👍', '🔥'];

/// Reactions shown under a bubble: each distinct emoji, plus a count when
/// both people reacted.
class ReactionPill extends StatelessWidget {
  const ReactionPill({super.key, required this.reactions, this.onTap});
  final List<Map<String, dynamic>> reactions;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    final emojis = reactions.map((r) => r['emoji'] as String).toSet();
    return Semantics(
      container: true,
      button: onTap != null,
      label: 'Reactions: ${reactions.map((r) => r['emoji']).join(' ')}',
      excludeSemantics: true,
      child: Material(
        color: c.surface,
        elevation: 1,
        shadowColor: Colors.black26,
        shape: StadiumBorder(side: BorderSide(color: c.border)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(emojis.join(), style: const TextStyle(fontSize: 14)),
                if (reactions.length > 1) ...[
                  const SizedBox(width: 3),
                  Text(
                    '${reactions.length}',
                    style: TextStyle(fontSize: 11.5, color: c.muted),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The quoted message shown at the top of a reply.
class ReplyQuote extends StatelessWidget {
  const ReplyQuote({
    super.key,
    required this.quoted,
    required this.author,
    required this.inMine,
    this.onTap,
  });

  /// The server's summary of the original, or null if it is unavailable.
  final Map<String, dynamic>? quoted;
  final String author;
  final bool inMine;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    final accent = inMine ? c.onMine : c.accent;
    final text = (inMine ? c.onMine : c.ink).withValues(alpha: .74);
    final icon = snippetIcon(quoted);
    return Semantics(
      container: true,
      button: onTap != null,
      label: 'Replying to $author: ${messageSnippet(quoted)}',
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: inMine ? Colors.white.withValues(alpha: .14) : c.accentSoft,
          child: InkWell(
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: accent, width: 3)),
              ),
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: accent,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        Icon(icon, size: 14, color: text),
                        const SizedBox(width: 4),
                      ],
                      Flexible(
                        child: Text(
                          messageSnippet(quoted),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.35,
                            color: text,
                            fontStyle: quoted == null
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Drag a message to the right to reply, as in most messengers. A reply
/// arrow fades in behind it, and a light tick confirms the threshold.
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({super.key, required this.child, this.onReply});
  final Widget child;
  final VoidCallback? onReply;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  static const trigger = 64.0;
  static const limit = 90.0;
  late final AnimationController _offset = AnimationController(
    vsync: this,
    upperBound: limit,
  );
  bool _armed = false;

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  void _drag(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    // Resist past the threshold so the bubble never runs away.
    final next =
        _offset.value + (_offset.value > trigger ? delta * .35 : delta);
    _offset.value = next.clamp(0, limit);
    final armed = _offset.value >= trigger;
    if (armed && !_armed) HapticFeedback.lightImpact();
    _armed = armed;
  }

  void _release([Object? _]) {
    if (_armed) widget.onReply?.call();
    _armed = false;
    _offset.animateTo(
      0,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onReply == null) return widget.child;
    final c = context.aida;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Follow the finger from touch-down, not from the end of the slop.
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragUpdate: _drag,
      onHorizontalDragEnd: _release,
      onHorizontalDragCancel: _release,
      child: AnimatedBuilder(
        animation: _offset,
        builder: (context, child) {
          final t = (_offset.value / trigger).clamp(0.0, 1.0);
          return Stack(
            alignment: Alignment.centerLeft,
            children: [
              Positioned(
                left: 2,
                child: Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: .6 + .4 * t,
                    // Turns solid once releasing would reply.
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: _armed ? c.accent : c.accentSoft,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.reply_rounded,
                        size: 18,
                        color: _armed ? c.onAccent : c.accent,
                      ),
                    ),
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(_offset.value, 0),
                child: child,
              ),
            ],
          );
        },
        child: widget.child,
      ),
    );
  }
}

class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder({
    required this.icon,
    required this.label,
    required this.color,
    required this.height,
    this.prominent = false,
  });
  final IconData icon;
  final String label;
  final Color color;
  final double height;
  final bool prominent;

  @override
  Widget build(BuildContext context) => Container(
    width: 240,
    height: height,
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: prominent ? 54 : 40,
          height: prominent ? 54 : 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: prominent ? .16 : 0),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: prominent ? 32 : 26, color: color),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(color: color.withValues(alpha: .8), fontSize: 12),
        ),
      ],
    ),
  );
}

/// The partner's typing state, as three softly pulsing dots in their bubble.
class TypingBubble extends StatefulWidget {
  const TypingBubble({super.key, required this.name});
  final String name;

  @override
  State<TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _pulse.value = .5;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    return Semantics(
      liveRegion: true,
      label: '${widget.name} is typing',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            color: c.theirs,
            border: Border.all(color: c.border),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
              bottomRight: Radius.circular(20),
              bottomLeft: Radius.circular(6),
            ),
          ),
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                final phase = (_pulse.value - i * .18) % 1;
                final lift = Curves.easeInOut.transform(
                  phase < .5 ? phase * 2 : (1 - phase) * 2,
                );
                return Padding(
                  padding: EdgeInsets.only(right: i == 2 ? 0 : 5),
                  child: Transform.translate(
                    offset: Offset(0, -2.5 * lift),
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: Color.lerp(
                          c.muted,
                          c.accent,
                          lift,
                        )!.withValues(alpha: .45 + .45 * lift),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

void openPhoto(BuildContext context, AidaApi api, String mediaId) =>
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, _, _) => PhotoScreen(api: api, mediaId: mediaId),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );

void openVideo(BuildContext context, AidaApi api, String mediaId) =>
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoScreen(api: api, mediaId: mediaId),
      ),
    );

class PhotoScreen extends StatelessWidget {
  const PhotoScreen({super.key, required this.api, required this.mediaId});

  final AidaApi api;
  final String mediaId;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      leading: IconButton(
        tooltip: 'Close',
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.close_rounded),
      ),
    ),
    extendBodyBehindAppBar: true,
    body: Center(
      child: InteractiveViewer(
        maxScale: 5,
        child: Hero(
          tag: 'media-$mediaId',
          child: Image.network(
            api.mediaUrl(mediaId).toString(),
            headers: api.mediaHeaders,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Text(
              'Image unavailable',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ),
      ),
    ),
  );
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
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Video'),
      ),
      body: Center(
        child: FutureBuilder<void>(
          future: _ready,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Text(
                'Video unavailable',
                style: TextStyle(color: Colors.white70),
              );
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return const CircularProgressIndicator(color: Colors.white70);
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
