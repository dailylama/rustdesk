import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Native macOS view that presents HEVC Main10 BT.2020 PQ frames in EDR.
///
/// Frames are pushed from Rust with `HdrViewSubmit(viewKey, ...)`; the view
/// itself takes no input, mouse and keyboard stay with Flutter.
class HdrView extends StatelessWidget {
  final String viewKey;
  final VoidCallback? onCreated;

  const HdrView({super.key, required this.viewKey, this.onCreated});

  @override
  Widget build(BuildContext context) {
    return AppKitView(
      viewType: 'rustdesk/hdr_view',
      creationParams: <String, dynamic>{'key': viewKey},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (_) => onCreated?.call(),
    );
  }
}
