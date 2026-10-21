import 'package:http/http.dart' as http;

String formatPrice(int cents) => '$cents';

Future<void> ping() async {
  await http.get(Uri.parse('https://api.shop.example/ping'));
}

Future<void> prices() async {
  await http.get(Uri.parse('https://api.shopapp.dev/v1/prices'));
}
