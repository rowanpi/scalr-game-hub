import 'package:flutter/material.dart';

import 'tuner/pitch_game_screen.dart';
import 'tuner/tuner_screen.dart';

void main() {
  runApp(const ScalrGameHubApp());
}

class ScalrGameHubApp extends StatelessWidget {
  const ScalrGameHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scalr Game Hub',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00E676)),
        useMaterial3: true,
      ),
      home: const GameHubHomeScreen(),
    );
  }
}

class GameHubHomeScreen extends StatelessWidget {
  const GameHubHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scalr Game Hub'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.sports_esports_rounded),
              title: const Text('Pitch Defender'),
              subtitle: const Text('Play note accuracy challenges'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PitchGameScreen()),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: const Text('Tuner'),
              subtitle: const Text('Tune your instrument'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TunerScreen()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
