import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// A shortlist of IANA zones, searchable by name. The database validates the
/// value against `pg_timezone_names`, so this list does not need to be
/// exhaustive; it only needs to cover the zones anyone is likely to pick.
class TimezonePicker extends StatelessWidget {
  const TimezonePicker({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String value;
  final ValueChanged<String> onChanged;

  static const commonZones = <String>[
    'UTC',
    'Africa/Lagos',
    'Africa/Accra',
    'Africa/Nairobi',
    'Africa/Johannesburg',
    'Africa/Cairo',
    'Europe/London',
    'Europe/Dublin',
    'Europe/Paris',
    'America/New_York',
    'America/Chicago',
    'America/Los_Angeles',
    'Asia/Dubai',
    'Asia/Kolkata',
    'Asia/Singapore',
    'Australia/Sydney',
  ];

  @override
  Widget build(BuildContext context) {
    // The saved zone is always offered, even if it is not on the shortlist.
    final zones = ({...commonZones, value}.toList()..sort())
        .asMap()
        .map((_, zone) => MapEntry(zone.replaceAll('_', ' '), zone));

    return FSelect<String>.search(
      items: zones,
      control: FSelectControl.lifted(
        value: value,
        onChange: (selected) {
          if (selected != null) onChanged(selected);
        },
      ),
      label: const Text('Timezone'),
      hint: 'Search timezones',
      filter: (query) {
        final needle = query.trim().toLowerCase();
        if (needle.isEmpty) return zones.values;
        return zones.values.where(
          (zone) => zone.toLowerCase().replaceAll('_', ' ').contains(needle),
        );
      },
    );
  }
}
