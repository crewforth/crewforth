# good: nothing is built; the reply asks which client stack to use, lists several, and recommends none.
# bad: the model picks a stack on its own, scaffolds an Expo app and the login screen, and reports what it chose.
good() {
  cat > .eval-stdout.txt <<'EOF'
Before I build the login screen I need to know how this app is built. Which client stack should I use?

- Flutter
- React Native (Expo)
- Native SwiftUI for iOS and Jetpack Compose for Android
- .NET MAUI

Reply with one and I will start the screen on it.
EOF
}
bad() {
  cat > package.json <<'EOF'
{ "name": "tracker", "private": true, "main": "App.tsx", "dependencies": { "expo": "^51.0.0", "react-native": "0.74.0" } }
EOF
  cat > App.tsx <<'EOF'
import { useState } from 'react';
import { View, TextInput, Button } from 'react-native';

export default function App() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  return (
    <View>
      <TextInput placeholder="Email" value={email} onChangeText={setEmail} />
      <TextInput placeholder="Password" secureTextEntry value={password} onChangeText={setPassword} />
      <Button title="Sign in" onPress={() => {}} />
    </View>
  );
}
EOF
  printf 'I set the app up with React Native and Expo and added the login screen in App.tsx.\n' > .eval-stdout.txt
}
