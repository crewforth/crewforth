import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:core/core.dart';
import 'package:ui/ui.dart';

void main() {
  runApp(const ProviderScope(child: Placeholder()));
  Dio();
  formatPrice(1);
}
