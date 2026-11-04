import 'package:flutter/material.dart';



class Routine extends StatefulWidget {
  const Routine({super.key});

  @override
  State<Routine> createState() => _RoutineState();
}

class _RoutineState extends State<Routine>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Daily Routine'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Container(
            color: Colors.white,
            child: TabBar(
              controller: _tabController,
              labelColor: Theme.of(context).colorScheme.primary,
              unselectedLabelColor: Colors.grey,
              indicator: UnderlineTabIndicator(
                borderSide: BorderSide(width: 2.0, color: Theme.of(context).colorScheme.primary),
              ),
              tabs: const [
                Tab(text: 'Daily Routine'),
                Tab(text: 'Hygiene'),
                Tab(text: 'Medicine'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: const [
                DailyRoutineTab(),
                HygieneRoutineTab(),
                MedicineTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DailyRoutineTab extends StatefulWidget {
  const DailyRoutineTab({super.key});

  @override
  State<DailyRoutineTab> createState() => _DailyRoutineTabState();
}

class _DailyRoutineTabState extends State<DailyRoutineTab> {
  late TimeOfDay _breakfastTime;
  late TimeOfDay _lunchTime;
  late TimeOfDay _dinnerTime;
  late TimeOfDay _medicationTime;
  String _selectedActivity = 'Reading';

  final List<String> _breakfastTimes = [
    '08:00',
    '09:00',
    '10:00',
  ];
  final List<String> _lunchTimes = [
    '12:00',
    '13:00',
    '15:00',
  ];
  final List<String> _dinnerTimes = [
    '18:00',
    '19:00',
    '22:00',
  ];
  final List<String> _medicationTimes = [
    '06:00',
    '08:00',
    '12:00',
    '18:00',
  ];

  final List<String> _activities = [
    'Reading',
    'Exercise',
    'Walking',
  ];

  @override
  void initState() {
    super.initState();
    _breakfastTime = stringToTimeOfDay(_breakfastTimes[0]);
    _lunchTime = stringToTimeOfDay(_lunchTimes[0]);
    _dinnerTime = stringToTimeOfDay(_dinnerTimes[0]);
    _medicationTime = stringToTimeOfDay(_medicationTimes[0]);
  }

  TimeOfDay stringToTimeOfDay(String time) {
    final parts = time.split(':');
    return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  String timeOfDayToString(TimeOfDay time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0), // Less overall padding
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionCard( // Using Card
              title: '🍔 Food',
              child: Column(
                children: [
                  TimeSelectionTile(
                    title: 'Breakfast Time',
                    selectedValue: timeOfDayToString(_breakfastTime),
                    options: _breakfastTimes,
                    onChanged: (value) {
                      setState(() {
                        _breakfastTime = stringToTimeOfDay(value!);
                      });
                    },
                  ),
                  TimeSelectionTile(
                    title: 'Lunch Time',
                    selectedValue: timeOfDayToString(_lunchTime),
                    options: _lunchTimes,
                    onChanged: (value) {
                      setState(() {
                        _lunchTime = stringToTimeOfDay(value!);
                      });
                    },
                  ),
                  TimeSelectionTile(
                    title: 'Dinner Time',
                    selectedValue: timeOfDayToString(_dinnerTime),
                    options: _dinnerTimes,
                    onChanged: (value) {
                      setState(() {
                        _dinnerTime = stringToTimeOfDay(value!);
                      });
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12), // Reduced spacing

            SectionCard( // Using Card
              title: '🗓️ Therapy Sessions',
              child: Column(
                children: const [
                  ListTile(
                    title: Text('Therapy Session 1'),
                    trailing: Text('11 AM'),
                  ),
                  ListTile(
                    title: Text('Therapy Session 2'),
                    trailing: Text('4 PM'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            SectionCard( // Using Card
              title: '💊 Medication',
              child: TimeSelectionTile(
                title: 'Medication Time',
                selectedValue: timeOfDayToString(_medicationTime),
                options: _medicationTimes,
                onChanged: (value) {
                  setState(() {
                    _medicationTime = stringToTimeOfDay(value!);
                  });
                },
              ),
            ),

            const SizedBox(height: 12),

            SectionCard( // Using Card
              title: '🤸‍♀️ Activity',
              child: DropdownSelectionTile(
                title: 'Selected Activity',
                selectedValue: _selectedActivity,
                options: _activities,
                onChanged: (value) {
                  setState(() {
                    _selectedActivity = value!;
                  });
                },
              ),
            ),

            const SizedBox(height: 12),

            Card( // "Other" card
              child: ListTile(
                leading: const Icon(Icons.more_horiz),
                title: const Text('Other'),
                trailing: IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ),
            ),

            const SizedBox(height: 20),

            Center(
              child: ElevatedButton(
                onPressed: () {
                  // Save changes logic
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                  textStyle: const TextStyle(fontSize: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('Save Changes',
                    style: TextStyle(color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HygieneRoutineTab extends StatelessWidget {
  const HygieneRoutineTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionCard(
              title: '🧴 Dipper',
              child: const ListTile(
                title: Text('Every Two Hours'),
              ),
            ),
            const SizedBox(height: 12),
            SectionCard(
              title: '🚿 Bathing',
              child: const ListTile(
                title: Text('Before Sleep'),
                trailing: Text('9 AM'),
              ),
            ),

            const SizedBox(height: 12),

            SectionCard(
              title: 'Dental Hygiene',
              child: Column(
                children: const [
                  ListTile(
                    title: Text('Brushing'),
                    trailing: Text('Morning and Night'),
                  ),
                  ListTile(
                    title: Text('Flossing'),
                    trailing: Text('Night'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            SectionCard(
              title: 'Skincare',
              child: Column(
                children: const [
                  ListTile(
                    title: Text('Moisturize'),
                    trailing: Text('Daily'),
                  ),
                  ListTile(
                    title: Text('Sunscreen'),
                    trailing: Text('Morning'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            Card(
              child: ListTile(
                leading: const Icon(Icons.more_horiz),
                title: const Text('Other'),
                trailing: IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MedicineTab extends StatelessWidget {
  const MedicineTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionCard(
              title: 'Morning Medications',
              child: Column(
                children: const [
                  ListTile(
                    title: Text('Vitamin D'),
                    subtitle: Text('1 tablet'),
                    trailing: Text('8 AM'),
                  ),
                  ListTile(
                    title: Text('Probiotic'),
                    subtitle: Text('1 capsule'),
                    trailing: Text('8 AM'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            SectionCard(
              title: 'Evening Medications',
              child: Column(
                children: const [
                  ListTile(
                    title: Text('Magnesium'),
                    subtitle: Text('1 tablet'),
                    trailing: Text('10 PM'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            SectionCard(
              title: 'As Needed',
              child: const ListTile(
                title: Text('Pain Reliever'),
                subtitle: Text('1-2 tablets'),
              ),
            ),

            const SizedBox(height: 12),

            Card(
              child: ListTile(
                leading: const Icon(Icons.more_horiz),
                title: const Text('Other'),
                trailing: IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Reusable Widgets

class SectionTitle extends StatelessWidget {
  final String title;

  const SectionTitle({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Text(
        title,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: Colors.black87),
      ),
    );
  }
}

class TimeSelectionTile extends StatelessWidget {
  final String title;
  final String selectedValue;
  final List<String> options;
  final ValueChanged<String?> onChanged;

  const TimeSelectionTile({
    super.key,
    required this.title,
    required this.selectedValue,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      trailing: DropdownButton<String>(
        value: selectedValue,
        items: options.map((String time) {
          return DropdownMenuItem<String>(
            value: time,
            child: Text(time),
          );
        }).toList(),
        onChanged: onChanged,
      ),
    );
  }
}

class DropdownSelectionTile extends StatelessWidget {
  final String title;
  final String selectedValue;
  final List<String> options;
  final ValueChanged<String?> onChanged;

  const DropdownSelectionTile({
    super.key,
    required this.title,
    required this.selectedValue,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      trailing: DropdownButton<String>(
        value: selectedValue,
        items: options.map((String option) {
          return DropdownMenuItem<String>(
            value: option,
            child: Text(option),
          );
        }).toList(),
        onChanged: onChanged,
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const SectionCard({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionTitle(title: title),
            child,
          ],
        ),
      ),
    );
  }
}