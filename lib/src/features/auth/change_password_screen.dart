import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../core/app_error.dart';
import '../../core/dev_log.dart';
import '../../services/staff_repository.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';

/// Shown to anyone still signed in with a password their administrator issued.
///
/// The administrator saw that password when they created or reset the account,
/// so until it is replaced it is a secret two people know, and either of them
/// could sign in. Nothing else in the app is reachable until this is done.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      logAction('password.change_own');
      await ref
          .read(staffRepositoryProvider)
          .changeOwnPassword(_passwordController.text);
      logDone('password.change_own');

      // The flag lives on the profile, and the router watches the stage
      // derived from it, so refreshing the profile is what lets the app
      // through to the clock-in screen.
      ref.invalidate(myProfileProvider);
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
      icon: FLucideIcons.lockKeyhole,
      title: 'Choose your password',
      subtitle:
          'You are signed in with a temporary password your administrator set '
          'up. Pick one only you know before carrying on.',
      maxWidth: 420,
      children: [
        if (me?.email != null) ...[
          FTileGroup(
            children: [
              FTile(
                prefix: const TileIcon(FLucideIcons.mail),
                title: Text(me!.email!),
                subtitle: Text(
                  me.fullName.isEmpty ? 'No name set' : me.fullName,
                ),
              ),
            ],
          ),
          const SizedBox(height: gutter),
        ],
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FTextFormField.password(
                control: FTextFieldControl.managed(
                  controller: _passwordController,
                ),
                label: const Text('New password'),
                description: const Text('At least 8 characters.'),
                enabled: !_busy,
                autofillHints: const [AutofillHints.newPassword],
                validator: (value) => (value ?? '').length < 8
                    ? 'Use at least 8 characters'
                    : null,
              ),
              const SizedBox(height: 14),
              FTextFormField.password(
                control: FTextFieldControl.managed(
                  controller: _confirmController,
                ),
                label: const Text('Confirm password'),
                enabled: !_busy,
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.done,
                onSubmit: (_) => _submit(),
                validator: (value) => value == _passwordController.text
                    ? null
                    : 'Both passwords must match',
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: gutter),
          ErrorNotice(error: AppError(_error!)),
        ],
        const SizedBox(height: 24),
        FButton(
          onPress: _busy ? null : _submit,
          child: _busy
              ? const FCircularProgress()
              : const ButtonLabel('Save password'),
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
