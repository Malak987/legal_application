import 'package:flutter/material.dart';

import '../../commonwidgets/product_data.dart';
import '../../constants/colors.dart';
import '../../models/product_model.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';
import '../checkout/shipping_screen.dart';


class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  CartScreenState createState() => CartScreenState();
}

class CartScreenState extends State<CartScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<Animation<Offset>> _slideAnimations;
  late Animation<double> _opacityAnimation;

  final List<Product> products = ProductData().products;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );

    _opacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    _slideAnimations = List.generate(products.length, (index) {
      Offset beginOffset;
      switch (index % 4) {
        case 0:
          beginOffset = const Offset(-1.0, 0.0); // From left
          break;
        case 1:
          beginOffset = const Offset(1.0, 0.0); // From right
          break;
        case 2:
          beginOffset = const Offset(0.0, -1.0); // From top
          break;
        case 3:
        default:
          beginOffset = const Offset(0.0, 1.0); // From bottom
          break;
      }
      return Tween<Offset>(
        begin: beginOffset,
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ));
    });

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return FadeTransition(
                opacity: _opacityAnimation,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [


                    SlideTransition(
                      position: _slideAnimations[0], // For the back button
                      child: const CustomAppBar(text: 'Cart', text1: ''),
                    ),
                    const SizedBox(height: 20),
                    Expanded(
                      child: ListView.builder(
                        itemCount: products.length,
                        itemBuilder: (context, index) {
                          return SlideTransition(
                            position: _slideAnimations[index],
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Card(
                                color: Colors.white,
                                elevation: 3,
                                child: Padding(
                                  padding: const EdgeInsets.all(12.0),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Image.asset(
                                        products[index].imagePath,
                                        width: 80,
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const SizedBox(height: 6,),
                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                              children: [
                                                Text1(
                                                  text1: products[index].price,
                                                  color: AppColors.text3Color,
                                                ),
                                                Text1(
                                                  text1: products[index].name,
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 7,),
                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                              children: [
                                                const Text2(
                                                  text2: '2',
                                                ),
                                                Row(
                                                  children: [
                                                    GestureDetector(
                                                      onTap: () {
                                                        // Handle quantity decrease
                                                      },
                                                      child: Container(
                                                        decoration:
                                                            const BoxDecoration(
                                                          color: AppColors
                                                              .text3Color,
                                                          shape:
                                                              BoxShape.circle,
                                                        ),
                                                        height: 25,
                                                        width: 25,
                                                        child: const Center(
                                                            child: Icon(
                                                                Icons.remove,
                                                                size: 20,
                                                                color: Colors
                                                                    .white)),
                                                      ),
                                                    ),
                                                    const Padding(
                                                      padding:
                                                          EdgeInsets.symmetric(
                                                              horizontal: 10),
                                                      child: Text1(
                                                          text1: '1kg',
                                                          size:
                                                              17), // Example quantity
                                                    ),
                                                    GestureDetector(
                                                      onTap: () {
                                                        // Handle quantity increase
                                                      },
                                                      child: Container(
                                                        decoration:
                                                            const BoxDecoration(
                                                          color: AppColors
                                                              .text3Color,
                                                          shape:
                                                              BoxShape.circle,
                                                        ),
                                                        height: 25,
                                                        width: 25,
                                                        child: const Center(
                                                            child: Icon(
                                                                Icons.add,
                                                                size: 20,
                                                                color: Colors
                                                                    .white)),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
                    SlideTransition(
                      position: _slideAnimations[
                          products.length - 1], // For the checkout button
                      child: CustomButton(
                        text: 'Proceed to Checkout',
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) =>  const ShippingAddressScreen()),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
