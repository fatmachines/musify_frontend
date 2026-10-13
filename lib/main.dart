import 'package:flutter/material.dart';

import 'tabs/home_tab.dart';
import 'tabs/library_tab.dart';
import 'tabs/search_tab.dart';

void main() {
  runApp(const MusifyApp());
}

class MusifyApp extends StatelessWidget {
  const MusifyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Musify',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1DB954),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF121212)),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFF181818),
        ),
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  // Each tab gets its own Navigator so pushed screens (e.g. a playlist) keep
  // the bottom bar visible and survive switching tabs.
  final _navigatorKeys = List.generate(3, (_) => GlobalKey<NavigatorState>());

  static const _tabs = [HomeTab(), SearchTab(), LibraryTab()];

  void _onSelect(int index) {
    if (index == _index) {
      _navigatorKeys[index].currentState?.popUntil((route) => route.isFirst);
    } else {
      setState(() => _index = index);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = _navigatorKeys[_index].currentState;
        if (navigator != null && await navigator.maybePop()) return;
        if (_index != 0) {
          setState(() => _index = 0);
        } else if (context.mounted) {
          Navigator.of(context).maybePop();
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < _tabs.length; i++)
              Navigator(
                key: _navigatorKeys[i],
                onGenerateRoute: (_) =>
                    MaterialPageRoute(builder: (_) => _tabs[i]),
              ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _onSelect,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.search),
              label: 'Search',
            ),
            NavigationDestination(
              icon: Icon(Icons.library_music_outlined),
              selectedIcon: Icon(Icons.library_music),
              label: 'Your Library',
            ),
          ],
        ),
      ),
    );
  }
}
