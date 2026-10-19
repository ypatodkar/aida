import 'package:flutter/material.dart';

import 'api.dart';
import 'design.dart';
import 'media_view.dart';

/// The couple's shared space: how long they've been together, and every photo
/// and video either of them has shared, across all topics, newest first.
class MomentsScreen extends StatefulWidget {
  const MomentsScreen({
    super.key,
    required this.api,
    required this.since,
    required this.myName,
    required this.partnerName,
    this.preview,
  });

  final AidaApi api;

  /// Pair creation time in epoch milliseconds, if the server provides it.
  final int? since;
  final String myName;
  final String partnerName;

  /// Design-preview media; when set, no network requests are made.
  final List<Map<String, dynamic>>? preview;

  @override
  State<MomentsScreen> createState() => _MomentsScreenState();
}

class _MomentsScreenState extends State<MomentsScreen> {
  final List<Map<String, dynamic>> _media = [];
  bool _loading = true;
  String? _problem;

  @override
  void initState() {
    super.initState();
    if (widget.preview != null) {
      _media.addAll(widget.preview!.reversed);
      _loading = false;
    } else {
      _load();
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
