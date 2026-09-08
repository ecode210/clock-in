import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../core/app_error.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';

/// Shown once, to the first account that signs in while the organisation has
/// no administrator. `claim_first_admin` checks a setup code that is only
/// readable from the database, and refuses to run again afterwards, so this is
/// not a standing privilege-escalation route.
class FirstAdminScreen extends ConsumerStatefulWidget {
  const FirstAdminScreen({super.key});

  @override
  ConsumerState<FirstAdminScreen> createState() => _FirstAdminScreenState();
}

class _FirstAdminScreenState extends ConsumerState<FirstAdminScreen> {
  final _codeController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _claim() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter the setup code.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(supabaseClientProvider).rpc(
        'claim_first_admin',
        params: {'p_setup_code': code},
      );
      ref.invalidate(myProfileProvider);
      ref.invalidate(adminExistsProvider);
    } catch (error) {
      if (mounted) setState(() => _error = errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(myProfileProvider).value;

    return AuthPage(
      icon: FLucideIcons.shieldCheck,
      title: 'Set up your organisation',
      subtitle:
          'No administrator has been set up yet. Enter the setup code to take '
          'the administrator role, then set the clock-in zone, choose the '
          'verification checks, and add your staff.',
      maxWidth: 440,
      children: [
        if (me != null) ...[
          FTileGroup(
            children: [
              FTile(
                prefix: FAvatar.raw(child: Text(me.initials)),
                title: Text(me.displayName),
                subtitle: Text(me.email ?? ''),
              ),
            ],
          ),
          const SizedBox(height: gutter),
        ],
        FTextField(
          control: FTextFieldControl.managed(controller: _codeController),
          label: const Text('Setup code'),
          description: const Text('Provided with your Supabase project setup.'),
          enabled: !_busy,
          autofocus: true,
          onSubmit: (_) => _claim(),
        ),
        if (_error != null) ...[
          const SizedBox(height: gutter),
          ErrorNotice(error: AppError(_error!)),
        ],
        const SizedBox(height: 24),
        FButton(
          onPress: _busy ? null : _claim,
          prefix: _busy ? null : const Icon(FLucideIcons.badgeCheck),
          child: _busy
              ? const FCircularProgress()
              : const Text('Make me the administrator'),
        ),
        const SizedBox(height: 10),
        FButton(
          variant: FButtonVariant.outline,
          onPress: _busy
              ? null
              : () => ref.read(supabaseClientProvider).auth.signOut(),
          child: const ButtonLabel('Sign out'),
        ),
      ],
    );
  }
}
