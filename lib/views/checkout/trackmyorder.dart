import 'package:flutter/material.dart';
import '../../constants/colors.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';
import 'order_status_screen.dart';

class TrackLegalServiceScreen extends StatelessWidget {
  const TrackLegalServiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(
                text: 'Track Legal Service',
                text1: '',
              ),
              const SizedBox(height: 20),
              _buildServiceTrackingDetails(),
              const SizedBox(height: 20),
              _buildTrackingSteps(),
              const SizedBox(height: 20),
              CustomButton(text: 'Need Help?', onTap: () {
                Navigator.push(context, MaterialPageRoute(builder:(_)=>OrderStatusScreen()));

                // Add support call or chat function
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildServiceTrackingDetails() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Color.fromARGB((0.2 * 255).toInt(), 158, 158, 158), // Equivalent to Colors.grey
            spreadRadius: 2,
            blurRadius: 5,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text1(text1: 'Booking ID: L123456', size: 18),
          SizedBox(height: 10),
          Text2(text2: 'Service Date: July 5, 2024'),
          SizedBox(height: 10),
          Text2(text2: 'Attorney: John Doe'),
          SizedBox(height: 10),
          Text2(text2: 'Location: 123 Main St, Springfield, USA'),
        ],
      ),
    );
  }

  Widget _buildTrackingSteps() {
    return Expanded(
      child: ListView(
        children: [
          _buildTrackingStep(
            step: 'Appointment Confirmed',
            date: '12/09/22',
            time: '9:30 AM',
            icon: Icons.calendar_today,
            isCompleted: true,
          ),
          _buildTrackingStep(
            step: 'Attorney Assigned',
            date: '12/09/22',
            time: '10:00 AM',
            icon: Icons.person,
            isCompleted: true,
          ),
          _buildTrackingStep(
            step: 'Attorney En Route',
            date: '12/09/22',
            time: '10:15 AM',
            icon: Icons.directions_walk,
            isCompleted: true,
          ),
          _buildTrackingStep(
            step: 'Legal Consultation in Progress',
            date: '12/09/22',
            time: '10:30 AM',
            icon: Icons.favorite,
            isCompleted: false,
          ),
          _buildTrackingStep(
            step: 'Service Completed',
            date: '',
            time: '',
            icon: Icons.check_circle,
            isCompleted: false,
          ),
        ],
      ),
    );
  }

  Widget _buildTrackingStep({
    required String step,
    required String date,
    required String time,
    required IconData icon,
    required bool isCompleted,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isCompleted ? AppColors.buttonColor : Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Color.fromARGB((0.2 * 255).toInt(), 158, 158, 158), // Equivalent to Colors.grey
            spreadRadius: 2,
            blurRadius: 5,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(icon, color: isCompleted ? Colors.white : Colors.grey),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text1(
                text1: step,
                size: 16,
                color: isCompleted ? Colors.white : Colors.grey,
              ),
              if (date.isNotEmpty && time.isNotEmpty)
                Text2(
                  text2: '$date $time',
                  color: isCompleted ? Colors.white : Colors.grey,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
