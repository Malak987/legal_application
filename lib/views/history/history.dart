/// Legacy disconnected sample screen with non-legal demo data. It is not routed
/// from the active app navigation; do not surface it as user history until it
/// reads the signed-in user's real cases/bookings from the repository.
import 'package:legalserviceapp/constants/colors.dart';
import 'package:flutter/material.dart';
// Platform fonts used for offline compatibility

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key}); // Added Key? key

  @override
  HistoryScreenState createState() => HistoryScreenState();
}

class HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
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
        title: Text(
          'History',
          style: TextStyle( // Apply Google Font
            color: Colors.black,
            fontSize: 24, // Slightly larger font size
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 1,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.black), //Added const
          onPressed: () {},
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search, color: Colors.black), //Added const
            onPressed: () {},
          ),
        ],
        bottom: PreferredSize(  // Wrap TabBar in PreferredSize
          preferredSize: const Size.fromHeight(56.0), //Explicit height
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16.0), //Horizontal padding
            child: TabBar(
              controller: _tabController,
              isScrollable: false, // Make tabs non-scrollable
              labelColor: Colors.white,
              unselectedLabelColor: Colors.black,
              labelStyle: TextStyle(fontWeight: FontWeight.w500), //Tab label styling
              indicator: BoxDecoration(
                color: AppColors.buttonColor,  // A bit lighter teal
                borderRadius: BorderRadius.circular(25), //More Rounded corners
              ),
              indicatorSize: TabBarIndicatorSize.tab, //Size indicator to tab

              tabs: const [  //Added const
                Tab(text: 'Last Places'),
                Tab(text: 'Last Caregivers'),
              ],
            ),
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children:  [  //Added const
          LastPlacesTab(),
          LastCaregiversTab(),
        ],
      ),
    );
  }
}

class LastPlacesTab extends StatelessWidget {
   LastPlacesTab({super.key});

  final List<Map<String, String>> places = [
    {'name': 'Home', 'date': '1 Dec - 11:45 AM', 'description': 'Usual Location'},
    {'name': 'Care Home', 'date': '1 Dec - 12 PM', 'description': 'Visited for checkup'},
    {'name': 'Hospital', 'date': '2 Dec - 3:30 PM', 'description': 'Emergency visit'},
    {'name': 'Clinic', 'date': '3 Dec - 9:00 AM', 'description': 'Routine checkup'},
    {'name': 'Office', 'date': '4 Dec - 1:00 PM', 'description': 'Meeting with client'},
  ];

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 15),
      itemCount: places.length,
      itemBuilder: (context, index) {
        return Card(
          elevation: 2,
          shadowColor: Colors.black26,
          color: Colors.white,
          margin: const EdgeInsets.symmetric(vertical: 5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.buttonColor.withAlpha((0.1 * 255).toInt()),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.location_on, color: AppColors.buttonColor, size: 28),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        places[index]['name']!,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 17,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        places[index]['date']!,
                        style: const TextStyle(fontSize: 14, color: Colors.black54),
                      ),
                      if (places[index]['description'] != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          places[index]['description']!,
                          style: const TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                      ]
                    ],
                  ),
                ),
                ElevatedButton(
                  onPressed: () {},
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.buttonColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
                  ),
                  child: const Text('View Map', style: TextStyle(fontSize: 14)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}




class LastCaregiversTab extends StatelessWidget {
  LastCaregiversTab({super.key});

  final List<Map<String, String>> caregivers = [
    {
      'name': 'Mariam Ahmed',
      'duration': '',
      'date': 'Dec 5 to Dec 12',
      'image': 'images/c3.png',
      'notes': 'Excellent service',
      'rating': '5.0'
    },
    {
      'name': 'John Doe',
      'duration': '',
      'date': 'Nov 20 to Dec 4',
      'image': 'images/c2.png',
      'notes': 'Good communication',
      'rating': '4.5'
    },
    {
      'name': 'Emily Watson',
      'duration': '',
      'date': 'Dec 1 to Dec 3',
      'image': 'images/c4.png',
      'notes': 'Caring and responsible',
      'rating': '4.0'
    },
    {
      'name': 'David Brown',
      'duration': '',
      'date': 'Dec 7 to Dec 12',
      'image': 'images/c5.png',
      'notes': 'Helpful and supportive',
      'rating': '3.5'
    },{
      'name': 'John Doe',
      'duration': '',
      'date': 'Nov 20 to Dec 4',
      'image': 'images/c2.png',
      'notes': 'Good communication',
      'rating': '4.5'
    },
    {
      'name': 'Emily Watson',
      'duration': '',
      'date': 'Dec 1 to Dec 3',
      'image': 'images/c4.png',
      'notes': 'Caring and responsible',
      'rating': '4.0'
    },
    {
      'name': 'David Brown',
      'duration': '',
      'date': 'Dec 7 to Dec 12',
      'image': 'images/c5.png',
      'notes': 'Helpful and supportive',
      'rating': '3.5'
    },{
      'name': 'John Doe',
      'duration': '',
      'date': 'Nov 20 to Dec 4',
      'image': 'images/c2.png',
      'notes': 'Good communication',
      'rating': '4.5'
    },
    {
      'name': 'Emily Watson',
      'duration': '',
      'date': 'Dec 1 to Dec 3',
      'image': 'images/c4.png',
      'notes': 'Caring and responsible',
      'rating': '4.0'
    },
    {
      'name': 'David Brown',
      'duration': '',
      'date': 'Dec 7 to Dec 12',
      'image': 'images/c5.png',
      'notes': 'Helpful and supportive',
      'rating': '3.5'
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(10.0),
      child: SingleChildScrollView(
        child: Column(
          children: caregivers.map((caregiver) {
            return Card(
              color: Colors.white,
              elevation: 2,
              margin: const EdgeInsets.symmetric(vertical: 5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    CircleAvatar(
                      radius: 30,
                      backgroundImage: AssetImage(caregiver['image']!),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            caregiver['name']!,
                            style: TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 18),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            ' ${caregiver['date']}',
                            style: const TextStyle(fontSize: 14, color: Colors.black54),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            caregiver['notes']!,
                            style: const TextStyle(fontSize: 13, color: Colors.grey),
                          ),
                          const SizedBox(height: 5),
                          Row(
                            children: [
                              const Icon(Icons.star, color: Colors.amber, size: 18),
                              const SizedBox(width: 4),
                              Text(
                                caregiver['rating']!,
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () {},
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.buttonColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                      ),
                      child: const Text(
                        'View Profile',
                        style: TextStyle(fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}