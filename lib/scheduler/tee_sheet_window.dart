import 'package:flutter/material.dart';

class TeeSheetWindow extends StatefulWidget {
  const TeeSheetWindow({super.key});

  @override
  State<TeeSheetWindow> createState() => _TeeSheetWindowState();
}

class _TeeSheetWindowState extends State<TeeSheetWindow> {
  static const int _startMinutes = 7 * 60;
  static const int _endMinutes = 19 * 60;
  static const int _intervalMinutes = 8;
  static const int _playerCount = 4;

  final Map<String, _TeeSlotEntry> _entries = <String, _TeeSlotEntry>{};
  late DateTime _selectedDay;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDay = DateTime(now.year, now.month, now.day);
  }

  List<int> get _timeSlots {
    return <int>[
      for (
        int minute = _startMinutes;
        minute <= _endMinutes;
        minute += _intervalMinutes
      )
        minute,
    ];
  }

  String _slotKey({
    required DateTime day,
    required int minutes,
    required int playerIndex,
  }) {
    final normalized = DateTime(day.year, day.month, day.day);
    return '${normalized.toIso8601String()}|$minutes|$playerIndex';
  }

  String _formatTime(int totalMinutes) {
    final hour24 = totalMinutes ~/ 60;
    final minute = totalMinutes % 60;
    final suffix = hour24 >= 12 ? 'PM' : 'AM';
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final minuteText = minute.toString().padLeft(2, '0');
    return '$hour12:$minuteText $suffix';
  }

  String _formatSelectedDay(DateTime day) {
    const weekdays = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${weekdays[day.weekday - 1]}, ${months[day.month - 1]} ${day.day}, ${day.year}';
  }

  Future<void> _editSlot({
    required int minutes,
    required int playerIndex,
  }) async {
    final key = _slotKey(
      day: _selectedDay,
      minutes: minutes,
      playerIndex: playerIndex,
    );
    final existing = _entries[key];
    final result = await showDialog<_TeeSlotDialogResult>(
      context: context,
      builder: (dialogContext) => _TeeSlotDialog(
        title: 'Player ${playerIndex + 1} - ${_formatTime(minutes)}',
        initialEntry: existing,
      ),
    );

    if (!mounted || result == null) return;

    setState(() {
      if (result.clearEntry) {
        _entries.remove(key);
      } else {
        _entries[key] = _TeeSlotEntry(
          firstName: result.firstName,
          lastName: result.lastName,
          phone: result.phone,
          notes: result.notes,
        );
      }
    });
  }

  Widget _buildSlotCell({required int minutes, required int playerIndex}) {
    final key = _slotKey(
      day: _selectedDay,
      minutes: minutes,
      playerIndex: playerIndex,
    );
    final entry = _entries[key];
    final isFilled = entry != null;
    final fullName = entry == null
        ? 'Open'
        : '${entry.firstName} ${entry.lastName}'.trim();
    final phone = entry?.phone.trim() ?? '';

    return SizedBox(
      width: 180,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _editSlot(minutes: minutes, playerIndex: playerIndex),
          child: Ink(
            decoration: BoxDecoration(
              color: isFilled
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surface,
              border: Border.all(
                color: isFilled
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fullName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  phone.isEmpty ? 'Tap to add player' : phone,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScheduleGrid() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            children: [
              const SizedBox(
                width: 96,
                child: Text(
                  'Time',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              for (
                int playerIndex = 0;
                playerIndex < _playerCount;
                playerIndex++
              )
                SizedBox(
                  width: 188,
                  child: Text(
                    'Player ${playerIndex + 1}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(14),
              ),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _timeSlots.length,
              itemBuilder: (context, index) {
                final minutes = _timeSlots[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 96,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: Text(
                            _formatTime(minutes),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                      for (
                        int playerIndex = 0;
                        playerIndex < _playerCount;
                        playerIndex++
                      )
                        _buildSlotCell(
                          minutes: minutes,
                          playerIndex: playerIndex,
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRightPanel() {
    return Container(
      width: 320,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Tee Sheet',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            _formatSelectedDay(_selectedDay),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: CalendarDatePicker(
              initialDate: _selectedDay,
              firstDate: DateTime(2025),
              lastDate: DateTime(2035),
              onDateChanged: (value) {
                setState(() {
                  _selectedDay = DateTime(value.year, value.month, value.day);
                });
              },
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: const Text(
              'Exploration only: this first pass keeps tee times in local screen state. Later we can wire POS, rates, and persistence.',
              style: TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 1320,
        height: 820,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  Text(
                    'Tee Sheet Explorer',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text('Concept v1'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Row(
                  children: [
                    Expanded(child: _buildScheduleGrid()),
                    const SizedBox(width: 16),
                    _buildRightPanel(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TeeSlotDialog extends StatefulWidget {
  const _TeeSlotDialog({required this.title, required this.initialEntry});

  final String title;
  final _TeeSlotEntry? initialEntry;

  @override
  State<_TeeSlotDialog> createState() => _TeeSlotDialogState();
}

class _TeeSlotDialogState extends State<_TeeSlotDialog> {
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _notesController;

  @override
  void initState() {
    super.initState();
    _firstNameController = TextEditingController(
      text: widget.initialEntry?.firstName ?? '',
    );
    _lastNameController = TextEditingController(
      text: widget.initialEntry?.lastName ?? '',
    );
    _phoneController = TextEditingController(
      text: widget.initialEntry?.phone ?? '',
    );
    _notesController = TextEditingController(
      text: widget.initialEntry?.notes ?? '',
    );
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _firstNameController,
              decoration: const InputDecoration(labelText: 'First Name'),
              autofocus: true,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _lastNameController,
              decoration: const InputDecoration(labelText: 'Last Name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _phoneController,
              decoration: const InputDecoration(labelText: 'Phone'),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _notesController,
              decoration: const InputDecoration(labelText: 'Notes'),
              maxLines: 3,
            ),
          ],
        ),
      ),
      actions: [
        if (widget.initialEntry != null)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop(
                const _TeeSlotDialogResult(
                  firstName: '',
                  lastName: '',
                  phone: '',
                  notes: '',
                  clearEntry: true,
                ),
              );
            },
            child: const Text('Clear'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            Navigator.of(context).pop(
              _TeeSlotDialogResult(
                firstName: _firstNameController.text.trim(),
                lastName: _lastNameController.text.trim(),
                phone: _phoneController.text.trim(),
                notes: _notesController.text.trim(),
                clearEntry: false,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _TeeSlotDialogResult {
  const _TeeSlotDialogResult({
    required this.firstName,
    required this.lastName,
    required this.phone,
    required this.notes,
    required this.clearEntry,
  });

  final String firstName;
  final String lastName;
  final String phone;
  final String notes;
  final bool clearEntry;
}

class _TeeSlotEntry {
  const _TeeSlotEntry({
    required this.firstName,
    required this.lastName,
    required this.phone,
    required this.notes,
  });

  final String firstName;
  final String lastName;
  final String phone;
  final String notes;
}
