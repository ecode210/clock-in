// ignore_for_file: experimental_member_use

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/app_error.dart';
import '../../models/profile.dart';
import '../../routing/router.dart';
import '../../services/passkey_service.dart';
import '../../services/supabase_providers.dart';
import 'widgets.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider);
    // Shared by both areas, each reached from its own Settings hub.
    final inAdminArea = GoRouterState.of(context).uri.path.startsWith('/admin');

    return AppScaffold(
      childPad: false,
      header: FHeader.nested(
        title: const Text('Account'),
        // The sub-pages are sibling routes rather than a pushed stack, so back
        // navigates to the hub explicitly.
        prefixes: [
          FHeaderAction.back(
            onPress: () => context.go(
              inAdminArea ? AppRoutes.adminSettings : AppRoutes.settings,
            ),
          ),
        ],
      ),
      child: AsyncSection(
        value: profile,
        onRetry: () => ref.invalidate(myProfileProvider),
        builder: (me) {
          if (me == null) {
            return const PagePadding(
              child: FCard(
                child: EmptyState(
                  icon: FLucideIcons.user,
                  title: 'No profile found',
                ),
              ),
            );
          }
          return PagePadding(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Identity(me: me),
                const SizedBox(height: gutter),
                _ProfileCard(me: me),
                const SizedBox(height: gutter),
                const _PasskeysCard(),
                const SizedBox(height: gutter),
                // Destructive, so it reads differently from the neutral
                // outlined actions above it and is harder to hit by accident.
                FButton(
                  variant: FButtonVariant.destructive,
                  onPress: () =>
                      ref.read(supabaseClientProvider).auth.signOut(),
                  prefix: const Icon(FLucideIcons.logOut),
                  child: const ButtonLabel('Sign out'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Avatar, name and role, so the screen opens with who you are signed in as.
class _Identity extends StatelessWidget {
  const _Identity({required this.me});

  final Profile me;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Row(
      children: [
        FAvatar.raw(size: 52, child: Text(me.initials)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                me.displayName,
                style: theme.titleStyle,
                overflow: TextOverflow.ellipsis,
              ),
              if (me.email != null)
                Text(
                  me.email!,
                  style: theme.mutedStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              const SizedBox(height: 6),
              StatusChip(
                label: me.role.label,
                icon: me.isAdmin
                    ? FLucideIcons.shieldCheck
                    : FLucideIcons.idCard,
                tone: me.isAdmin ? ChipTone.positive : ChipTone.neutral,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProfileCard extends ConsumerStatefulWidget {
  const _ProfileCard({required this.me});

  final Profile me;

  @override
  ConsumerState<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends ConsumerState<_ProfileCard> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.me.fullName,
  );
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(supabaseClientProvider).rpc(
        'update_my_profile',
        params: {'p_full_name': _nameController.text.trim()},
      );
      ref.invalidate(myProfileProvider);
      if (mounted) showSnack(context, 'Name updated.');
    } catch (error) {
      if (mounted) showSnack(context, errorMessage(error), isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Your details',
      children: [
        FTextField(
          control: FTextFieldControl.managed(controller: _nameController),
          label: const Text('Full name'),
          enabled: !_saving,
        ),
        if (widget.me.staffId != null) ...[
          const SizedBox(height: 12),
          Text(
            'Staff ID: ${widget.me.staffId}',
            style: context.theme.mutedStyle,
          ),
        ],
        const SizedBox(height: gutter),
        FButton(
          onPress: _saving ? null : _save,
          child: ButtonLabel(_saving ? 'Saving…' : 'Save name'),
        ),
      ],
    );
  }
}

/// Passkey enrolment. Registering here is what makes the admin's "require
/// passkey" setting usable for a given staff member.
///
/// An account holds one passkey and enrols it once. Removing it is an
/// administrator's job, so a stolen password cannot be used to swap the
/// registered device for the attacker's own, which is the whole reason the
/// clock-in passkey check is worth anything.
class _PasskeysCard extends ConsumerStatefulWidget {
  const _PasskeysCard();

  @override
  ConsumerState<_PasskeysCard> createState() => _PasskeysCardState();
}

class _PasskeysCardState extends ConsumerState<_PasskeysCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String success) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(myPasskeysProvider);
      if (mounted) showSnack(context, success);
    } catch (error) {
      if (mounted) showSnack(context, errorMessage(error), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final passkeys = ref.watch(myPasskeysProvider);
    final requirePasskey =
        ref.watch(orgSettingsProvider).value?.requirePasskey ?? false;

    return SectionCard(
      title: 'Passkey',
      subtitle: requirePasskey
          ? 'A passkey is required to clock in. It uses the fingerprint or '
                'face unlock on this device.'
          : 'Optional. Lets you sign in with your fingerprint or face '
                'instead of a password.',
      children: [
        AsyncSection(
          value: passkeys,
          onRetry: () => ref.invalidate(myPasskeysProvider),
          builder: (items) {
            if (items.isEmpty) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'No passkey registered yet. Set one up on the device you '
                    'carry to work. You only get to do this once, so use '
                    'your own phone rather than a shared one.',
                    style: context.theme.mutedStyle,
                  ),
                  const SizedBox(height: 12),
                  FButton(
                    variant: FButtonVariant.outline,
                    onPress: _busy
                        ? null
                        : () => _run(
                            () => ref
                                .read(passkeyServiceProvider)
                                .register(friendlyName: 'This device'),
                            'Passkey set up on this device.',
                          ),
                    prefix: const Icon(FLucideIcons.plus),
                    child: ButtonLabel(
                      _busy ? 'Working…' : 'Set up a passkey on this device',
                    ),
                  ),
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FTileGroup(
                  children: [
                    for (final passkey in items)
                      FTile(
                        prefix: const TileIcon(FLucideIcons.keyRound),
                        title: Text(passkey.friendlyName ?? 'Passkey'),
                        subtitle: Text(_describe(passkey)),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Changing to a different device needs an administrator to '
                  'reset this first.',
                  style: context.theme.mutedStyle,
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  static String _describe(Passkey passkey) {
    final date = DateFormat.yMMMd();
    final added = 'Added ${date.format(passkey.createdAt.toLocal())}';
    final used = passkey.lastUsedAt;
    return used == null ? added : '$added · used ${date.format(used.toLocal())}';
  }
}
