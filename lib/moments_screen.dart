import 'package:flutter/material.dart';

import 'api.dart';
import 'design.dart';
import 'media_view.dart';

/// The couple's shared space: how long they've been together, the messages
/// they chose to keep, and every photo and video either of them has shared,
/// across all topics, newest first.
class MomentsScreen extends StatefulWidget {
  const MomentsScreen({
    super.key,
    required this.api,
    required this.since,
    required this.myId,
    required this.myName,
    required this.partnerName,
    this.preview,
    this.previewKept,
  });

  final AidaApi api;

  /// Pair creation time in epoch milliseconds, if the server provides it.
  final int? since;
  final String myId;
  final String myName;
  final String partnerName;

  /// Design-preview media; when set, no network requests are made.
  final List<Map<String, dynamic>>? preview;
  final List<Map<String, dynamic>>? previewKept;

  @override
  State<MomentsScreen> createState() => _MomentsScreenState();
}

class _MomentsScreenState extends State<MomentsScreen> {
  final List<Map<String, dynamic>> _media = [];
  List<Map<String, dynamic>> _kept = [];
  bool _loading = true;
  String? _problem;

  @override
  void initState() {
    super.initState();
    if (widget.preview != null) {
      _media.addAll(widget.preview!.reversed);
      _kept = [...?widget.previewKept];
      _loading = false;
    } else {
      _load();
      _loadKept();
    }
  }

  Future<void> _loadKept() async {
    try {
      final kept = (await widget.api.kept())['kept'] as List;
      if (mounted) setState(() => _kept = kept.cast<Map<String, dynamic>>());
    } catch (_) {
      // The photo grid reports connection problems; kept messages just wait.
    }
  }

  Future<void> _unkeep(Map<String, dynamic> message) async {
    final before = _kept;
    setState(() => _kept = [..._kept]..remove(message));
    if (widget.preview != null) return;
    try {
      await widget.api.keep(message['id'] as int, false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _kept = before);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t remove it. Try again.')),
      );
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _problem = null;
      _media.clear();
    });
    try {
      // Messages page oldest-first, so each page is prepended to keep the
      // grid newest-first while later pages are still arriving.
      var cursor = 0;
      while (true) {
        final page = await widget.api.messages(after: cursor, topicId: null);
        if (!mounted) return;
        final items = (page['messages'] as List).cast<Map<String, dynamic>>();
        final found = items.where(
          (m) =>
              (m['kind'] == 'image' || m['kind'] == 'video') &&
              m['mediaId'] != null,
        );
        if (found.isNotEmpty) {
          setState(() => _media.insertAll(0, found.toList().reversed));
        }
        if (page['hasMore'] != true || items.isEmpty) break;
        cursor = items.last['id'] as int;
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _problem = error is ApiException
              ? error.message
              : 'Moments could not load. Check your connection.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    final since = widget.since;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 112,
            leading: IconButton(
              tooltip: 'Back to chat',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsetsDirectional.only(
                start: 56,
                bottom: 14,
              ),
              title: Text(
                'Moments',
                style: TextStyle(
                  fontFamily: serif,
                  fontSize: 28,
                  fontWeight: FontWeight.w400,
                  color: c.ink,
                ),
              ),
            ),
          ),
          if (since != null)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              sliver: SliverToBoxAdapter(
                child: TogetherCard(
                  together: Together(since),
                  names: '${widget.myName} & ${widget.partnerName}',
                ),
              ),
            ),
          if (_kept.isNotEmpty) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 12),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    const Eyebrow('Kept'),
                    const Spacer(),
                    Text(
                      '${_kept.length}',
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverList.separated(
                itemCount: _kept.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final item = _kept[index];
                  return _KeptCard(
                    api: widget.api,
                    message: item,
                    author: item['senderId'] == widget.myId
                        ? widget.myName
                        : widget.partnerName,
                    onRemove: () => _unkeep(item),
                  );
                },
              ),
            ),
          ],
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 12),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  const Eyebrow('Photos & videos'),
                  const Spacer(),
                  if (_media.isNotEmpty)
                    Text(
                      '${_media.length}',
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                ],
              ),
            ),
          ),
          if (_problem != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(_problem!, style: TextStyle(color: c.muted)),
                    ),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              ),
            ),
          if (_media.isEmpty && !_loading && _problem == null)
            SliverToBoxAdapter(
              child: _EmptyMoments(partner: widget.partnerName),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                ),
                itemCount: _media.length,
                itemBuilder: (context, index) =>
                    _MomentTile(api: widget.api, item: _media[index]),
              ),
            ),
          if (_loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

class TogetherCard extends StatelessWidget {
  const TogetherCard({super.key, required this.together, required this.names});
  final Together together;
  final String names;

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    final soft = c.onHero.withValues(alpha: .62);
    final celebrating = together.daysUntilNext == 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
      decoration: BoxDecoration(
        color: c.hero,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Eyebrow(names, color: soft)),
              AidaMark(size: 40, breathing: true, second: c.warm),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            celebrating && together.anniversary
                ? 'Happy anniversary'
                : 'Day ${together.day}',
            style: TextStyle(
              fontFamily: serif,
              fontSize: 54,
              height: 1,
              color: c.onHero,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Together since ${longDate(together.since)}',
            style: TextStyle(color: soft, fontSize: 13.5),
          ),
          const SizedBox(height: 20),
          Container(height: 1, color: c.onHero.withValues(alpha: .12)),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(Icons.auto_awesome_outlined, size: 18, color: c.warm),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  together.nextLabel,
                  style: TextStyle(
                    color: c.onHero,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                together.countdown,
                style: TextStyle(color: c.warm, fontSize: 13.5),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MomentTile extends StatelessWidget {
  const _MomentTile({required this.api, required this.item});
  final AidaApi api;
  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    final id = item['mediaId'] as String;
    final video = item['kind'] == 'video';
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Material(
        color: c.surfaceMuted,
        child: InkWell(
          onTap: () =>
              video ? openVideo(context, api, id) : openPhoto(context, api, id),
          child: video
              ? Center(
                  child: Icon(
                    Icons.play_circle_outline_rounded,
                    size: 34,
                    color: c.accent,
                    semanticLabel: 'Video',
                  ),
                )
              : Hero(
                  tag: 'media-$id',
                  child: Image.network(
                    api.mediaUrl(id).toString(),
                    headers: api.mediaHeaders,
                    fit: BoxFit.cover,
                    cacheWidth: 360,
                    semanticLabel: 'Photo',
                    frameBuilder: (_, child, frame, synchronous) =>
                        AnimatedOpacity(
                          opacity: synchronous || frame != null ? 1 : 0,
                          duration: const Duration(milliseconds: 300),
                          child: child,
                        ),
                    errorBuilder: (_, _, _) => Icon(
                      Icons.image_not_supported_outlined,
                      color: c.muted,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// A kept message: text set as a quote, or a photo or video thumbnail.
class _KeptCard extends StatelessWidget {
  const _KeptCard({
    required this.api,
    required this.message,
    required this.author,
    required this.onRemove,
  });
  final AidaApi api;
  final Map<String, dynamic> message;
  final String author;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    final kind = message['kind'];
    final mediaId = message['mediaId'] as String?;
    final sent = DateTime.fromMillisecondsSinceEpoch(
      message['createdAt'] as int,
    );
    final details =
        '$author · ${longDate(sent)} · ${message['topicName'] ?? 'Everyday'}';
    Widget body;
    if (kind == 'text') {
      body = Text(
        '“${message['text']}”',
        maxLines: 6,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: serif,
          fontSize: 21,
          height: 1.3,
          color: c.ink,
        ),
      );
    } else {
      final video = kind == 'video';
      body = Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 64,
              height: 64,
              color: c.surfaceMuted,
              child: video || mediaId == null
                  ? Icon(Icons.play_circle_outline_rounded, color: c.accent)
                  : Image.network(
                      api.mediaUrl(mediaId).toString(),
                      headers: api.mediaHeaders,
                      fit: BoxFit.cover,
                      cacheWidth: 200,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.image_not_supported_outlined,
                        color: c.muted,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 14),
          Text(
            video ? 'Video' : 'Photo',
            style: TextStyle(color: c.ink, fontSize: 15.5),
          ),
        ],
      );
    }
    return Material(
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: mediaId == null
            ? null
            : () => kind == 'video'
                  ? openVideo(context, api, mediaId)
                  : openPhoto(context, api, mediaId),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 6, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(right: 12), child: body),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove from Moments',
                    onPressed: onRemove,
                    icon: Icon(
                      Icons.bookmark_remove_outlined,
                      size: 20,
                      color: c.muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyMoments extends StatelessWidget {
  const _EmptyMoments({required this.partner});
  final String partner;

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 28, 36, 28),
      child: Column(
        children: [
          Icon(Icons.photo_library_outlined, size: 30, color: c.accent),
          const SizedBox(height: 14),
          Text(
            'Your photos will gather here.',
            textAlign: TextAlign.center,
            style: TextStyle(fontFamily: serif, fontSize: 24, color: c.ink),
          ),
          const SizedBox(height: 8),
          Text(
            'Everything you and $partner share in any topic, in one place.',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.muted, height: 1.6),
          ),
        ],
      ),
    );
  }
}
