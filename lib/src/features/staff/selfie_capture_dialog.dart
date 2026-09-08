import 'package:camera/camera.dart';
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../../core/app_error.dart';
import '../../services/selfie_service.dart';
import '../shared/widgets.dart';

/// Captures a photo from the live camera feed. Deliberately does not offer a
/// file picker: the point of the check is that the photo is taken at the moment
/// of clocking in, not chosen from the gallery.
///
/// Takes over the whole screen rather than sitting in a dialog, because that
/// is how a phone camera behaves and the viewfinder needs the room.
class SelfieCaptureDialog extends StatefulWidget {
  const SelfieCaptureDialog({super.key});

  /// Pushed on the root navigator, above the shell: the viewfinder should
  /// cover the tab bar, and the clock-in flow that opens this puts a blocking
  /// overlay over the shell while it runs.
  static Future<CapturedSelfie?> show(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push<CapturedSelfie>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const SelfieCaptureDialog(),
      ),
    );
  }

  @override
  State<SelfieCaptureDialog> createState() => _SelfieCaptureDialogState();
}

class _SelfieCaptureDialogState extends State<SelfieCaptureDialog> {
  CameraController? _controller;
  String? _error;
  bool _initialising = true;
  bool _capturing = false;
  CapturedSelfie? _preview;

  @override
  void initState() {
    super.initState();
    _startCamera();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _startCamera() async {
    setState(() {
      _initialising = true;
      _error = null;
    });

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw const AppError(
          'No camera was found on this device.',
          code: 'no_camera',
        );
      }

      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();

      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _initialising = false;
      });
    } on CameraException catch (error) {
      if (!mounted) return;
      setState(() {
        _initialising = false;
        _error = switch (error.code) {
          'CameraAccessDenied' ||
          'CameraAccessDeniedWithoutPrompt' ||
          'NotAllowedError' =>
            'Camera access is blocked. Allow it in your browser settings, '
                'then reload the page.',
          'NotFoundError' || 'NotReadableError' =>
            'The camera could not be started. Close any other app using it '
                'and try again.',
          _ => error.description ?? 'The camera could not be started.',
        };
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _initialising = false;
        _error = errorMessage(error);
      });
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || _capturing) return;

    setState(() => _capturing = true);
    try {
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        _preview = CapturedSelfie(
          bytes: bytes,
          mimeType: file.mimeType ?? 'image/jpeg',
        );
      });
    } catch (error) {
      if (mounted) setState(() => _error = errorMessage(error));
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return FScaffold(
      childPad: false,
      header: FHeader.nested(
        title: const Text('Take your photo'),
        prefixes: [
          FHeaderAction(
            icon: const Icon(FLucideIcons.x),
            semanticsLabel: 'Cancel',
            onPress: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 4, gutter, 12),
              child: Text(
                'Look at the camera. Your supervisor uses this photo to '
                'confirm it was really you.',
                textAlign: TextAlign.center,
                style: theme.mutedStyle,
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: gutter),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: ColoredBox(
                    color: theme.colors.muted,
                    child: SizedBox.expand(child: _viewfinder()),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _actions(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _viewfinder() {
    if (_preview != null) {
      return Image.memory(_preview!.bytes, fit: BoxFit.cover);
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(gutter),
          child: ErrorNotice(error: AppError(_error!), onRetry: _startCamera),
        ),
      );
    }
    if (_initialising || _controller == null) {
      return const Center(child: FCircularProgress());
    }
    // FittedBox keeps the preview filling the frame without distorting it,
    // which matters because the browser picks the aspect ratio, not us.
    final size = _controller!.value.previewSize;
    if (size == null) return CameraPreview(_controller!);
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: size.height,
        height: size.width,
        child: CameraPreview(_controller!),
      ),
    );
  }

  List<Widget> _actions() {
    if (_preview != null) {
      return [
        FButton(
          size: FButtonSizeVariant.lg,
          onPress: () => Navigator.of(context).pop(_preview),
          prefix: const Icon(FLucideIcons.check),
          child: const ButtonLabel('Use this photo'),
        ),
        const SizedBox(height: 10),
        FButton(
          variant: FButtonVariant.outline,
          onPress: () => setState(() => _preview = null),
          prefix: const Icon(FLucideIcons.rotateCw),
          child: const ButtonLabel('Retake'),
        ),
      ];
    }

    return [
      FButton(
        size: FButtonSizeVariant.lg,
        onPress: (_controller == null || _capturing) ? null : _capture,
        prefix: _capturing
            ? const FCircularProgress()
            : const Icon(FLucideIcons.camera),
        child: ButtonLabel(_capturing ? 'Capturing…' : 'Capture photo'),
      ),
    ];
  }
}
