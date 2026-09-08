import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../core/app_error.dart';
import '../../core/dev_log.dart';
import '../../services/passkey_service.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      // The router redirects as soon as the session lands, so there is nothing
      // to do here on success.
    } catch (error) {
      if (mounted) setState(() => _error = errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signInWithPassword() async {
    if (!_formKey.currentState!.validate()) return;
    final email = _emailController.text.trim();
    await _run(() async {
      logAction('sign_in.password', {'email': email});
      await ref.read(supabaseClientProvider).auth.signInWithPassword(
        email: email,
        password: _passwordController.text,
      );
      logDone('sign_in.password');
    });
  }

  Future<void> _signInWithPasskey() => _run(() async {
    logAction('sign_in.passkey');
    await ref.read(passkeyServiceProvider).signIn();
    logDone('sign_in.passkey');
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return AuthPage(
      icon: FLucideIcons.clock,
      title: 'Staff Clock-In',
      subtitle: 'Sign in to mark your attendance',
      children: [
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FTextFormField.email(
                control: FTextFieldControl.managed(
                  controller: _emailController,
                ),
                label: const Text('Work email'),
                hint: 'you@work.com',
                enabled: !_busy,
                autofillHints: const [AutofillHints.username],
                validator: (value) {
                  final text = (value ?? '').trim();
                  if (text.isEmpty) return 'Enter your work email';
                  if (!text.contains('@')) return 'Enter a valid email';
                  return null;
                },
              ),
              const SizedBox(height: 14),
              FTextFormField.password(
                control: FTextFieldControl.managed(
                  controller: _passwordController,
                ),
                label: const Text('Password'),
                enabled: !_busy,
                textInputAction: TextInputAction.done,
                onSubmit: (_) => _signInWithPassword(),
                validator: (value) =>
                    (value ?? '').isEmpty ? 'Enter your password' : null,
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
          onPress: _busy ? null : _signInWithPassword,
          child: _busy ? const FCircularProgress() : const Text('Sign in'),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(child: FDivider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('or', style: theme.captionStyle),
            ),
            const Expanded(child: FDivider()),
          ],
        ),
        const SizedBox(height: 20),
        FButton(
          variant: FButtonVariant.outline,
          onPress: _busy ? null : _signInWithPasskey,
          prefix: const Icon(FLucideIcons.fingerprint),
          child: const ButtonLabel('Sign in with passkey'),
        ),
        const SizedBox(height: 14),
        Text(
          'Passkeys use the fingerprint or face unlock on this device. Add one '
          'from your account page after signing in.',
          textAlign: TextAlign.center,
          style: theme.captionStyle,
        ),
      ],
    );
  }
}
