const gateway = (host: 'api.shopapp.dev', port: 443);

Future<void> stock(Dio dio, String id) async {
  await dio.get('/v1/stock/$id');
}
