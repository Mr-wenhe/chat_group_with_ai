import 'dart:io';

import 'package:chat_group/core/models/attachment_data_uri.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// An inline video player bubble for chat messages.
///
/// Manages [VideoPlayerController] and [ChewieController] lifecycle,
/// releasing resources in [dispose]. Shows a loading placeholder until
/// initialization completes, then renders the full player with controls.
class VideoBubble extends StatefulWidget {
  final String localPath;
  final bool isUser;

  const VideoBubble({super.key, required this.localPath, required this.isUser});

  @override
  State<VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<VideoBubble> {
  late final VideoPlayerController _controller;
  ChewieController? _chewieController;

  @override
  void initState() {
    super.initState();
    _controller = !isAttachmentDataUri(widget.localPath)
        ? VideoPlayerController.file(File(widget.localPath))
        : VideoPlayerController.networkUrl(Uri.parse(widget.localPath));
    _controller.initialize().then((_) {
      if (!mounted) return;
      // Build ChewieController after initialization so aspectRatio is available.
      _chewieController = ChewieController(
        videoPlayerController: _controller,
        autoPlay: false,
        looping: false,
        aspectRatio: _controller.value.aspectRatio,
        placeholder: const Center(child: CircularProgressIndicator()),
      );
      setState(() {});
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ratio = _chewieController?.aspectRatio ?? 1.0;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240, maxHeight: 320),
      child: AspectRatio(
        aspectRatio: ratio,
        child: _chewieController != null
            ? Chewie(controller: _chewieController!)
            : Container(
                color: Colors.black.withValues(alpha: 0.08),
                child: const Center(child: CircularProgressIndicator()),
              ),
      ),
    );
  }
}
