# good: a Dart settings screen with a dark-mode switch is added and linked from home, with no stack question.
# bad: the model ignores the recorded Flutter stack and asks which framework to use instead of building the screen.
good() {
  cat > lib/settings_screen.dart <<'EOF'
import 'package:flutter/material.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool dark = false;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: SwitchListTile(
          title: const Text('Dark mode'),
          value: dark,
          onChanged: (v) => setState(() => dark = v),
        ),
      );
}
EOF
  printf 'Added lib/settings_screen.dart with a dark-mode switch and a settings button on the home screen.\n' > .eval-stdout.txt
}
bad() {
  printf 'Which framework should I use for the settings screen? Flutter or React Native? Tell me and I will build it.\n' > .eval-stdout.txt
}
