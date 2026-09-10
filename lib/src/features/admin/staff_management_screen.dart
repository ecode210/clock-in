import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../core/app_error.dart';
import '../../core/formatters.dart';
import '../../models/profile.dart';
import '../../models/staff_passkey.dart';
import '../../services/passkey_service.dart';
import '../../services/staff_repository.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';

class StaffManagementScreen extends ConsumerWidget {
  const StaffManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final staff = ref.watch(staffListProvider);

    return AppScaffold(
      childPad: false,
      header: FHeader(
        title: const Text('Staff'),
        suffixes: [
          HeaderAction(
            icon: FLucideIcons.refreshCw,
            semanticsLabel: 'Refresh',
            onPress: () => ref.invalidate(staffListProvider),
          ),
          HeaderAction(
            icon: FLucideIcons.userPlus,
            semanticsLabel: 'Add staff',
            onPress: () => _createStaff(context, ref),
          ),
        ],
      ),
      child: AsyncSection(
        value: staff,
        onRetry: () => ref.invalidate(staffListProvider),
        builder: (people) {
          final deactivated = people.where((p) => !p.isActive).length;
          final active = people.where((p) => p.isActive).length;
          final admins = people.where((p) => p.isAdmin).length;

          return PagePadding(
            maxWidth: 700,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (deactivated > 0) ...[
                  FAlert(
                    icon: const Icon(FLucideIcons.triangleAlert),
                    title: Text(
                      '$deactivated account${deactivated == 1 ? '' : 's'} '
                      'cannot clock in',
                    ),
                    subtitle: const Text(
                      'Deactivated accounts are blocked until you reactivate '
                      'them. Anyone who registered themselves starts here.',
                    ),
                  ),
                  const SizedBox(height: gutter),
                ],
                if (people.isEmpty)
                  const FCard(
                    child: EmptyState(
                      icon: FLucideIcons.users,
                      title: 'No staff yet',
                      message: 'Add your first staff member to get started.',
                    ),
                  )
                else
                  FTileGroup(
                    label: Text(
                      '${people.length} account'
                      '${people.length == 1 ? '' : 's'}',
                    ),
                    description: Text(
                      '$active active · $admins administrator'
                      '${admins == 1 ? '' : 's'}',
                    ),
                    children: [
                      for (final person in people) _StaffTile(person: person),
                    ],
                  ),
                const SizedBox(height: gutter),
                FButton(
                  onPress: () => _createStaff(context, ref),
                  prefix: const Icon(FLucideIcons.userPlus),
                  child: const ButtonLabel('Add a staff member'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StaffTile extends ConsumerWidget with FTileMixin {
  const _StaffTile({required this.person});

  final Profile person;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMe = ref.watch(currentUserIdProvider) == person.id;

    return FTile(
      prefix: FAvatar.raw(child: Text(person.initials)),
      title: Text(person.displayName, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(person.email ?? '', overflow: TextOverflow.ellipsis),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (isMe)
                const StatusChip(label: 'You', icon: FLucideIcons.user),
              StatusChip(
                label: person.role.label,
                icon: person.isAdmin
                    ? FLucideIcons.shieldCheck
                    : FLucideIcons.idCard,
                tone: person.isAdmin ? ChipTone.positive : ChipTone.neutral,
              ),
              if (!person.isActive)
                const StatusChip(
                  label: 'Deactivated',
                  icon: FLucideIcons.userMinus,
                  tone: ChipTone.negative,
                ),
              if (person.staffId != null)
                StatusChip(label: 'ID ${person.staffId}'),
            ],
          ),
        ],
      ),
      suffix: FButton.icon(
        variant: FButtonVariant.ghost,
        semanticsLabel: 'Manage ${person.displayName}',
        onPress: () => _showActions(context, ref, person, isMe: isMe),
        child: const Icon(FLucideIcons.ellipsisVertical),
      ),
    );
  }
}

/// Per-person actions come up from the bottom rather than as a dropdown: the
/// targets are far easier to hit with a thumb, which is where this app is used.
Future<void> _showActions(
  BuildContext context,
  WidgetRef ref,
  Profile person, {
  required bool isMe,
}) async {
  final action = await showFSheet<String>(
    context: context,
    side: FLayout.btt,
    mainAxisMaxRatio: null,
    useSafeArea: true,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, gutter),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              person.displayName,
              style: sheetContext.theme.titleStyle,
            ),
          ),
          FTileGroup(
            children: [
              FTile(
                prefix: const TileIcon(FLucideIcons.pencil),
                title: const Text('Edit details'),
                onPress: () => Navigator.of(sheetContext).pop('edit'),
              ),
              FTile(
                prefix: const TileIcon(FLucideIcons.lockKeyhole),
                title: const Text('Reset password'),
                onPress: () => Navigator.of(sheetContext).pop('reset'),
              ),
              FTile(
                prefix: const TileIcon(FLucideIcons.keyRound),
                title: const Text('Passkey'),
                onPress: () => Navigator.of(sheetContext).pop('passkey'),
              ),
              if (!isMe)
                FTile(
                  prefix: TileIcon(
                    person.isActive
                        ? FLucideIcons.userMinus
                        : FLucideIcons.circleCheck,
                  ),
                  title: Text(
                    person.isActive ? 'Deactivate' : 'Reactivate',
                  ),
                  onPress: () => Navigator.of(sheetContext).pop('toggle'),
                ),
              if (!isMe)
                FTile(
                  prefix: const TileIcon(FLucideIcons.trash2),
                  title: const Text('Delete account'),
                  onPress: () => Navigator.of(sheetContext).pop('delete'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          FButton(
            variant: FButtonVariant.outline,
            onPress: () => Navigator.of(sheetContext).pop(),
            child: const ButtonLabel('Cancel'),
          ),
        ],
      ),
    ),
  );

  if (action == null || !context.mounted) return;
  final repository = ref.read(staffRepositoryProvider);

  switch (action) {
    case 'edit':
      await _editStaff(context, ref, person);

    case 'passkey':
      await showFDialog<void>(
        context: context,
        builder: (dialogContext, style, animation) =>
            _PasskeyDialog(person: person),
      );

    case 'toggle':
      await _guard(
        context,
        ref,
        () => repository.setActive(person.id, isActive: !person.isActive),
        person.isActive
            ? '${person.displayName} can no longer clock in.'
            : '${person.displayName} can clock in again.',
      );

    case 'reset':
      final confirmed = await confirmAction(
        context,
        title: 'Reset password?',
        message:
            'A new temporary password will be generated for '
            '${person.displayName}. Their current password stops working '
            'immediately.',
        confirmLabel: 'Reset',
      );
      if (!confirmed || !context.mounted) return;

      try {
        final credentials = await repository.resetPassword(userId: person.id);
        if (!context.mounted) return;
        await _showCredentials(
          context,
          title: 'New password for ${person.displayName}',
          email: person.email ?? '',
          password: credentials.temporaryPassword,
        );
      } catch (error) {
        if (context.mounted) {
          showSnack(context, errorMessage(error), isError: true);
        }
      }

    case 'delete':
      final confirmed = await confirmAction(
        context,
        title: 'Delete ${person.displayName}?',
        message:
            'This removes the account and all of its attendance history. '
            'Deactivating instead keeps the records for your reports.',
        confirmLabel: 'Delete permanently',
        destructive: true,
      );
      if (confirmed && context.mounted) {
        await _guard(
          context,
          ref,
          () => repository.delete(person.id),
          'Account deleted.',
        );
      }
  }
}

Future<void> _guard(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() action,
  String success,
) async {
  try {
    await action();
    ref.invalidate(staffListProvider);
    if (context.mounted) showSnack(context, success);
  } catch (error) {
    if (context.mounted) showSnack(context, errorMessage(error), isError: true);
  }
}

Future<void> _editStaff(
  BuildContext context,
  WidgetRef ref,
  Profile person,
) async {
  final result = await showFDialog<_StaffDetails>(
    context: context,
    builder: (dialogContext, style, animation) =>
        _EditStaffDialog(person: person),
  );
  if (result == null || !context.mounted) return;

  await _guard(
    context,
    ref,
    () async {
      await ref.read(staffRepositoryProvider).updateDetails(
        userId: person.id,
        fullName: result.fullName,
        staffId: result.staffId,
        role: result.role,
      );
      ref.invalidate(myProfileProvider);
    },
    'Details updated.',
  );
}

Future<void> _createStaff(BuildContext context, WidgetRef ref) async {
  final credentials = await showFDialog<StaffCredentials>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext, style, animation) => const _CreateStaffDialog(),
  );

  if (credentials == null) return;
  ref.invalidate(staffListProvider);

  if (context.mounted) {
    await _showCredentials(
      context,
      title: 'Account created',
      email: credentials.email ?? '',
      password: credentials.temporaryPassword,
    );
  }
}

class _StaffDetails {
  const _StaffDetails({
    required this.fullName,
    required this.staffId,
    required this.role,
  });

  final String fullName;
  final String staffId;
  final UserRole role;
}

class _EditStaffDialog extends StatefulWidget {
  const _EditStaffDialog({required this.person});

  final Profile person;

  @override
  State<_EditStaffDialog> createState() => _EditStaffDialogState();
}

class _EditStaffDialogState extends State<_EditStaffDialog> {
  late final _nameController = TextEditingController(
    text: widget.person.fullName,
  );
  late final _staffIdController = TextEditingController(
    text: widget.person.staffId ?? '',
  );
  late UserRole _role = widget.person.role;

  @override
  void dispose() {
    _nameController.dispose();
    _staffIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: 'Edit details',
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTextField(
          control: FTextFieldControl.managed(controller: _nameController),
          label: const Text('Full name'),
        ),
        const SizedBox(height: 12),
        FTextField(
          control: FTextFieldControl.managed(controller: _staffIdController),
          label: const Text('Staff ID'),
          description: const Text('Optional.'),
        ),
        const SizedBox(height: 12),
        _RoleSelect(
          value: _role,
          onChange: (value) => setState(() => _role = value),
        ),
      ],
    ),
    actions: [
      FButton(
        onPress: () => Navigator.of(context).pop(
          _StaffDetails(
            fullName: _nameController.text.trim(),
            staffId: _staffIdController.text.trim(),
            role: _role,
          ),
        ),
        child: const ButtonLabel('Save'),
      ),
      FButton(
        variant: FButtonVariant.outline,
        onPress: () => Navigator.of(context).pop(),
        child: const ButtonLabel('Cancel'),
      ),
    ],
  );
}

class _CreateStaffDialog extends ConsumerStatefulWidget {
  const _CreateStaffDialog();

  @override
  ConsumerState<_CreateStaffDialog> createState() => _CreateStaffDialogState();
}

class _CreateStaffDialogState extends ConsumerState<_CreateStaffDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _staffIdController = TextEditingController();

  UserRole _role = UserRole.staff;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _staffIdController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final result = await ref.read(staffRepositoryProvider).create(
        fullName: _nameController.text.trim(),
        email: _emailController.text.trim(),
        staffId: _staffIdController.text.trim(),
        role: _role,
      );
      if (mounted) Navigator.of(context).pop(result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorMessage(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: 'Add a staff member',
    content: Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FTextFormField(
            control: FTextFieldControl.managed(controller: _nameController),
            label: const Text('Full name'),
            enabled: !_busy,
            validator: (value) =>
                (value ?? '').trim().isEmpty ? 'Enter their name' : null,
          ),
          const SizedBox(height: 12),
          FTextFormField.email(
            control: FTextFieldControl.managed(controller: _emailController),
            label: const Text('Work email'),
            enabled: !_busy,
            validator: (value) {
              final text = (value ?? '').trim();
              if (text.isEmpty) return 'Enter their email';
              if (!text.contains('@')) return 'Enter a valid email';
              return null;
            },
          ),
          const SizedBox(height: 12),
          FTextField(
            control: FTextFieldControl.managed(controller: _staffIdController),
            label: const Text('Staff ID'),
            description: const Text('Optional.'),
            enabled: !_busy,
          ),
          const SizedBox(height: 12),
          _RoleSelect(
            value: _role,
            enabled: !_busy,
            onChange: (value) => setState(() => _role = value),
          ),
          if (_error != null) ...[
            const SizedBox(height: gutter),
            ErrorNotice(error: AppError(_error!)),
          ],
        ],
      ),
    ),
    actions: [
      FButton(
        onPress: _busy ? null : _submit,
        child: ButtonLabel(_busy ? 'Creating…' : 'Create account'),
      ),
      FButton(
        variant: FButtonVariant.outline,
        onPress: _busy ? null : () => Navigator.of(context).pop(),
        child: const ButtonLabel('Cancel'),
      ),
    ],
  );
}

class _RoleSelect extends StatelessWidget {
  const _RoleSelect({
    required this.value,
    required this.onChange,
    this.enabled = true,
  });

  final UserRole value;
  final ValueChanged<UserRole> onChange;
  final bool enabled;

  @override
  Widget build(BuildContext context) => FSelect<UserRole>(
    items: {for (final option in UserRole.values) option.label: option},
    control: FSelectControl.lifted(
      value: value,
      onChange: (selected) {
        if (selected != null) onChange(selected);
      },
    ),
    label: const Text('Role'),
    enabled: enabled,
  );
}

/// The passkey is the strongest check the app has, and it is only as good as
/// the enrolment behind it. This is where an administrator sees which device is
/// registered and clears it when someone changes phone: the one route by
/// which a staff member can ever enrol a second time.
class _PasskeyDialog extends ConsumerStatefulWidget {
  const _PasskeyDialog({required this.person});

  final Profile person;

  @override
  ConsumerState<_PasskeyDialog> createState() => _PasskeyDialogState();
}

class _PasskeyDialogState extends ConsumerState<_PasskeyDialog> {
  bool _busy = false;

  Future<void> _reset() async {
    final confirmed = await confirmAction(
      context,
      title: 'Reset passkey?',
      message:
          '${widget.person.displayName} will no longer be able to verify with '
          'their current device, and can set up a new one from their account '
          'page the next time they sign in.',
      confirmLabel: 'Reset',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(staffRepositoryProvider).resetPasskey(widget.person.id);
      // Staff sheet lists via RPC; Account (and clock-in prompts) list via
      // Auth. Both read the same table, but live in separate providers, so a
      // self-reset would leave Account showing the old credential otherwise.
      ref.invalidate(staffPasskeysProvider(widget.person.id));
      ref.invalidate(myPasskeysProvider);
      if (mounted) showSnack(context, 'Passkey reset.');
    } catch (error) {
      if (mounted) showSnack(context, errorMessage(error), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final overview = ref.watch(staffPasskeysProvider(widget.person.id));
    final hasPasskey = overview.value?.passkeys.isNotEmpty ?? false;

    return AppDialog(
      title: 'Passkey',
      message: widget.person.displayName,
      content: AsyncSection(
        value: overview,
        onRetry: () => ref.invalidate(staffPasskeysProvider(widget.person.id)),
        builder: (data) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (data.passkeys.isEmpty)
              Text(
                'No passkey registered. ${widget.person.displayName} can set '
                'one up from their account page after signing in.',
                style: context.theme.mutedStyle,
              )
            else
              FTileGroup(
                children: [
                  for (final passkey in data.passkeys)
                    FTile(
                      prefix: const TileIcon(FLucideIcons.keyRound),
                      title: Text(passkey.friendlyName),
                      subtitle: TileSubtitle(_describePasskey(passkey)),
                    ),
                ],
              ),
            if (data.events.isNotEmpty) ...[
              const SizedBox(height: gutter),
              const SectionLabel('History'),
              FTileGroup(
                children: [
                  for (final event in data.events)
                    FTile(
                      prefix: TileIcon(_eventIcon(event.action)),
                      title: Text(event.action.label),
                      subtitle: TileSubtitle(_describeEvent(event)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (hasPasskey)
          FButton(
            variant: FButtonVariant.destructive,
            onPress: _busy ? null : _reset,
            child: ButtonLabel(_busy ? 'Working…' : 'Reset passkey'),
          ),
        FButton(
          variant: FButtonVariant.outline,
          onPress: () => Navigator.of(context).pop(),
          child: const ButtonLabel('Close'),
        ),
      ],
    );
  }

  static String _describePasskey(StaffPasskey passkey) => [
    'Enrolled ${formatShortDay(passkey.createdAt)}',
    if (passkey.lastUsedAt != null)
      'last used ${formatShortDay(passkey.lastUsedAt!)}',
    // Worth saying out loud: a synced credential lives on every device the
    // person signs into their Apple or Google account with, so one passkey
    // does not always mean one phone.
    if (passkey.backedUp) 'synced to their other devices',
  ].join(' · ');

  static String _describeEvent(PasskeyEvent event) {
    final when =
        '${formatShortDay(event.createdAt)} at ${formatTime(event.createdAt)}';
    return event.actorName == null ? when : '$when · by ${event.actorName}';
  }

  static IconData _eventIcon(PasskeyEventAction action) => switch (action) {
    PasskeyEventAction.enrolled => FLucideIcons.circleCheck,
    PasskeyEventAction.deleted => FLucideIcons.circleX,
    PasskeyEventAction.reset => FLucideIcons.rotateCcw,
  };
}

/// The temporary password is only ever shown here, so make it easy to copy and
/// obvious that it will not be shown again.
Future<void> _showCredentials(
  BuildContext context, {
  required String title,
  required String email,
  required String password,
}) {
  return showFDialog<void>(
    context: context,
    builder: (dialogContext, style, animation) => AppDialog(
      title: title,
      message:
          'Share these sign-in details with the staff member. The password is '
          'not stored anywhere and cannot be shown again. They will be asked '
          'to choose their own the first time they sign in.',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CopyableField(label: 'Email', value: email),
          const SizedBox(height: 10),
          _CopyableField(label: 'Temporary password', value: password),
        ],
      ),
      actions: [
        FButton(
          onPress: () => Navigator.of(dialogContext).pop(),
          child: const ButtonLabel('Done'),
        ),
      ],
    ),
  );
}

class _CopyableField extends StatelessWidget {
  const _CopyableField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: theme.colors.muted,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.captionStyle),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  style: theme.bodyStyle.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          FButton.icon(
            variant: FButtonVariant.ghost,
            semanticsLabel: 'Copy $label',
            onPress: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (context.mounted) showSnack(context, '$label copied.');
            },
            child: const Icon(FLucideIcons.copy),
          ),
        ],
      ),
    );
  }
}
