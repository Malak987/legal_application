import 'package:flutter/material.dart';
import '../../constants/colors.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/detailstext1.dart';


class OrderStatusScreen extends StatelessWidget {
  const OrderStatusScreen({super.key});

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
                text: 'Service Status',
                text1: '',
              ),
              const SizedBox(height: 20),
              _buildStatusTile('Appointment Scheduled', Icons.calendar_today, '12/09/22 9:30 AM', true),
              _buildStatusTile('Attorney Assigned', Icons.person, '12/09/22 10:00 AM', true),
              _buildStatusTile('En Route to Location', Icons.directions_walk, '12/09/22 10:15 AM', true),
              _buildStatusTile('Consultation in Progress', Icons.favorite, '', false),
              _buildStatusTile('Service Completed', Icons.check_circle, '', false),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusTile(String status, IconData icon, String time, bool isCompleted) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      margin: const EdgeInsets.only(bottom: 12),
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
                text1: status,
                size: 16,
                color: isCompleted ? Colors.white : Colors.grey,
              ),
              if (time.isNotEmpty)
                Text(
                  time,
                  style: TextStyle(
                    color: isCompleted ? Colors.white : Colors.grey,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
