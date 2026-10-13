import 'package:flutter/material.dart';

import 'services/player_service.dart';
import 'tabs/home_tab.dart';
import 'tabs/library_tab.dart';
import 'tabs/search_tab.dart';
import 'theme.dart';
import 'widgets/bottom_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PlayerService.init();
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
      darkTheme: buildTheme(),
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
        // The bar fades over the content, so content runs underneath it.
        extendBody: true,
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
        bottomNavigationBar: BottomBar(index: _index, onSelect: _onSelect),
      ),
    );
  }
}
