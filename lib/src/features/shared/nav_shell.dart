import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

class NavDestinationSpec {
  const NavDestinationSpec({
    required this.path,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Shared chrome for both role areas.
///
/// The bottom tab bar is the primary pattern, because the app is used on a
/// phone at the door. A wide browser window swaps it for a sidebar, but the
/// destinations and the content column stay the same so the app still reads
/// like a mobile app on a desktop screen.
class AppNavShell extends StatelessWidget {
  const AppNavShell({
    required this.destinations,
    required this.location,
    required this.child,
    this.title,
    super.key,
  });

  final List<NavDestinationSpec> destinations;
  final String location;
  final Widget child;
  final String? title;

  static const _sidebarBreakpoint = 900.0;

  int get _selectedIndex {
    var best = 0;
    var bestLength = -1;
    for (var i = 0; i < destinations.length; i++) {
      final path = destinations[i].path;
      final matches =
          location == path || (path != '/' && location.startsWith('$path/'));
      if (matches && path.length > bestLength) {
        best = i;
        bestLength = path.length;
      }
    }
    return best;
  }

  void _go(BuildContext context, int index) {
    final target = destinations[index].path;
    if (target != location) context.go(target);
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width >= _sidebarBreakpoint) {
      return _wide(context);
    }

    final selected = _selectedIndex;
    return FScaffold(
      childPad: false,
      footer: FBottomNavigationBar(
        index: selected,
        safeAreaBottom: true,
        onChange: (index) => _go(context, index),
        children: [
          for (var i = 0; i < destinations.length; i++)
            FBottomNavigationBarItem(
              icon: Icon(
                i == selected
                    ? destinations[i].selectedIcon
                    : destinations[i].icon,
              ),
              label: Text(destinations[i].label),
            ),
        ],
      ),
      child: child,
    );
  }

  Widget _wide(BuildContext context) {
    final theme = context.theme;
    final selected = _selectedIndex;

    return FScaffold(
      childPad: false,
      sidebar: FSidebar(
        header: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
          child: Row(
            children: [
              Icon(FLucideIcons.clock, size: 18, color: theme.colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title ?? 'Clock-In',
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.body.md.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colors.foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
        children: [
          FSidebarGroup(
            children: [
              for (var i = 0; i < destinations.length; i++)
                FSidebarItem(
                  icon: Icon(
                    i == selected
                        ? destinations[i].selectedIcon
                        : destinations[i].icon,
                  ),
                  label: Text(destinations[i].label),
                  selected: i == selected,
                  onPress: () => _go(context, i),
                ),
            ],
          ),
        ],
      ),
      child: child,
    );
  }
}
