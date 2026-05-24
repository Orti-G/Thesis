import 'package:flutter/material.dart';
import 'main.dart'; 

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  // Vibrant brand oranges
  final List<Color> _bgColors = [
    const Color(0xFFF47B20), // Primary vibrant orange
    const Color(0xFFE86A17), // Slightly deeper orange
    const Color(0xFFFF9540), // Brighter warm orange
  ];

  // Slide content data - Updated with dynamic icons and removed descriptions
  final List<Map<String, dynamic>> _slides = [
    {
      'header': 'Live Insights',
      'title': 'Navigating the Real-Time Telemetry Dashboard',
      'icon': Icons.insights_rounded, // Unique icon 1
      'image': 'https://images.unsplash.com/photo-1551288049-bebda4e38f71?auto=format&fit=crop&w=600&q=80', 
    },
    {
      'header': 'Cost Control',
      'title': 'Interpreting Billing Tiers & Predictive Forecasting',
      'icon': Icons.monetization_on_rounded, // Unique icon 2
      'image': 'https://images.unsplash.com/photo-1554224155-8d04cb21cd6c?auto=format&fit=crop&w=600&q=80', 
    },
    {
      'header': 'Safety First',
      'title': 'Managing Safety Alerts & Custom Device Configuration',
      'icon': Icons.health_and_safety_rounded, // Unique icon 3
      'image': 'https://images.unsplash.com/photo-1633265486064-086b219458ec?q=80&w=1470&auto=format&fit=crop&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHx8fA%3D%3D', 
    },
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        // Light theme: soft orange glow fading into clean white
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _bgColors[_currentPage].withOpacity(0.15), 
              const Color(0xFFF9F9F9), 
              Colors.white, 
            ],
            stops: const [0.0, 0.4, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Combined Carousel Section
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  onPageChanged: (int page) {
                    setState(() {
                      _currentPage = page;
                    });
                  },
                  itemCount: _slides.length,
                  itemBuilder: (context, index) {
                    return Column(
                      children: [
                        // Image
                        Expanded(
                          flex: 4,
                          child: Container(
                            margin: const EdgeInsets.all(16.0),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(32.0),
                              image: DecorationImage(
                                image: NetworkImage(_slides[index]['image']),
                                fit: BoxFit.cover,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.05),
                                  blurRadius: 10,
                                  offset: const Offset(0, 5),
                                ),
                              ],
                            ),
                          ),
                        ),
                        
                        // Text & Icon Content
                        Expanded(
                          flex: 4,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32.0),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                // Dynamically loading the unique icon for each slide
                                Icon(
                                  _slides[index]['icon'],
                                  size: 48,
                                  color: _bgColors[_currentPage],
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _slides[index]['header'].toString().toUpperCase(),
                                  style: const TextStyle(
                                    color: Colors.black54, 
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 2.0,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  _slides[index]['title'],
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.black87, 
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                    height: 1.2,
                                  ),
                                ),
                                // Description text removed entirely here
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),

              // Bottom Navigation
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(
                        _slides.length,
                        (index) => GestureDetector(
                          onTap: () {
                            _pageController.animateToPage(
                              index,
                              duration: const Duration(milliseconds: 400),
                              curve: Curves.easeInOut,
                            );
                          },
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 12.0),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              height: 4.0,
                              width: index == _currentPage ? 32.0 : 24.0,
                              decoration: BoxDecoration(
                                color: index == _currentPage
                                    ? const Color(0xFFF47B20) 
                                    : Colors.grey.shade300,
                                borderRadius: BorderRadius.circular(4.0),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: TextButton(
                        onPressed: () {
                          if (_currentPage < _slides.length - 1) {
                            _pageController.nextPage(
                              duration: const Duration(milliseconds: 400),
                              curve: Curves.easeInOut,
                            );
                          } else {
                            Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const MainScreen(),
                              ),
                            );
                          }
                        },
                        style: TextButton.styleFrom(
                          backgroundColor: const Color(0xFFF47B20),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16.0),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _currentPage == _slides.length - 1 ? 'Get Started' : 'Continue',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(
                              Icons.arrow_forward,
                              color: Colors.white,
                              size: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
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